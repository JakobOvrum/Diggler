module diggler.bot;

import std.algorithm;
import std.array;
import std.exception : enforce;
import std.range : assumeSorted, ElementType, insertInPlace, isInputRange;
import std.socket : Socket;
import std.uni : isWhite;

public import diggler.attribute;
public import diggler.context;
public import diggler.command;
import diggler.commandqueue;
import diggler.defaultcommands;

import irc.client;
import irc.eventloop;
import irc.tracker;

package void wakeFiber(IrcEventLoop eventLoop, CommandQueue.CommandFiber fiber)
{
	eventLoop.post(() {
		fiber.resume();
	});
}

/**
 * IRC bot.
 *
 * A single bot can be connected to multiple networks. The bot's
 * username and real name are shared across all networks, but
 * the nick name can differ.
 */
final class Bot
{
	private:
	CommandQueue _commandQueue;
	IrcEventLoop _eventLoop;
	ClientEventHandler[] eventHandlers;
	ICommandSet[] _commandSets;

	string[] adminList; // Sorted

	string preferredNick; // Nick can differ across connections
	string _userName;
	string _realName;
	string _commandPrefix;

	package:
	final class ClientEventHandler : IrcClient
	{
		IrcTracker tracker;
		string[] initialChannels;
		IrcUser[string] adminCache;

		this(Socket socket, string[] initialChannels)
		{
			super(socket);

			this.initialChannels = initialChannels;
			this.tracker = track(this);
			this.tracker.start();

			super.onConnect ~= &handleConnect;
			super.onMessage ~= &handleMessage;
		}

		void handleConnect()
		{
			foreach(channel; initialChannels)
				super.join(channel);
		}

		void handleMessage(IrcUser user, in char[] target, in char[] message)
		{
			import std.string : stripLeft;

			bool isPm = target == super.nickName;
			auto replyTarget = (isPm? user.nickName : target).idup;

			// handle commands
			if(message.startsWith(commandPrefix))
			{
				const(char)[] msg = message[commandPrefix.length .. $];

				// TODO: use isWhite
				auto cmdName = msg.munch("^ ");

				// TODO: urgh, again Phobos bugs prevent std.algorithm from handling this
				ICommandSet cmdSet;
				Command* cmd;
				foreach(set; _commandSets)
				{
					if(auto c = set.getCommand(cmdName))
					{
						cmdSet = set;
						cmd = c;
						break;
					}
				}

				if(cmdSet is null)
					return; // No such command

				if(isPm && cmd.channelOnly)
					return;

				//enforce(cmdSearch.empty, format(`multiple handlers for command "%s"`, cmdName));

				auto cmdArgs = msg.stripLeft().idup;

				auto ctx = Context(this.outer, this, tracker, replyTarget, user, isPm);

				commandQueue.post(cmdSet, ctx, () {
					try cmd.handler(cmdArgs);
					catch(CommandArgumentException e)
					{
						if(auto next = e.next)
							super.sendf(replyTarget, "error: %s (%s)", e.msg, next.msg);
						else
							super.sendf(replyTarget, "error: %s", e.msg);
					}
					/+catch(Exception e)
					{
						debug client.sendf(user.nickName, e.toString());
						else
							throw e;
					}+/
				});
			}
		}
	}

	final CommandQueue commandQueue() @property @safe pure nothrow
	{
		return _commandQueue;
	}

	public:
	/// Bot configuration.
	static struct Configuration
	{
		/// All fields are required.
		string nickName, userName, realName, commandPrefix;
		deprecated alias nick = nickName;
	}

	/**
	 * Create a new bot with the given configuration.
	 *
	 * If $(D eventLoop) is passed, connections by this bot will be handled
	 * by the given event loop. Otherwise, the bot shares a default
	 * event loop with all other bots created in the same thread.
	 */
	this(Configuration conf, string file = __FILE__, size_t line = __LINE__)
	{
		import diggler.eventloop : defaultEventLoop;
		this(conf, defaultEventLoop, file, line);
	}

	/// Ditto
	this(Configuration conf, IrcEventLoop eventLoop, string file = __FILE__, size_t line = __LINE__)
	{
		this._eventLoop = eventLoop;

		this.commandPrefix = enforce(conf.commandPrefix, "must specify command prefix", file, line);
		this.preferredNick = enforce(conf.nickName, "must specify nick name", file, line);
		this._userName = enforce(conf.userName, "must specify user name", file, line);
		this._realName = enforce(conf.realName, "must specify the real name field", file, line);

		this._commandQueue = new CommandQueue();

		registerCommands(new DefaultCommands(this));
	}

	/// Boolean whether or not command invocations are allowed in private messages.
	bool allowPMCommands = true;

	final:
	/// The event loop handling connections for this bot.
	IrcEventLoop eventLoop() @property pure nothrow
	{
		return _eventLoop;
	}

	/// The command prefix used to invoke bot commands through chat messages.
	string commandPrefix() const @property pure nothrow
	{
		return _commandPrefix;
	}

	/// Ditto
	void commandPrefix(string newPrefix) @property pure nothrow
	{
		_commandPrefix = newPrefix;
	}

	/// The username of this bot.
	string userName() @property pure nothrow
	{
		return _userName;
	}

	/// The real name of this bot.
	string realName() @property pure nothrow
	{
		return _realName;
	}

	/// $(D InputRange) of all networks the bot is connected
	/// to, where each network is represented by its $(D IrcClient) connection.
	auto clients() @property pure nothrow
	{
		return eventHandlers.map!((IrcClient client) => client)();
	}

	/// $(D InputRange) of all command sets ($(DPREF command, ICommandSet))
	/// registered with the bot.
	auto commandSets() @property pure nothrow
	{
		return _commandSets;
	}

	/**
	 * Request a new nick name for the bot on all networks.
	 *
	 * The bot may have different nick names on different networks.
	 * Use the $(D nick) property on the clients in $(MREF Bot.clients)
	 * to get the current nick names.
	 */
	void nickName(in char[] newNick) @property
	{
		foreach(client; clients)
			client.nickName = newNick;
	}

	/// Ditto
	void nickName(string newNick) @property
	{
		foreach(client; clients)
			client.nickName = newNick;
	}

	deprecated alias nick = nickName;

	/**
	 * Connect the bot to a network described in the IRC URL url.
	 *
	 * The new connection is automatically added to the event loop
	 * used by this bot.
	 * Returns:
	 *    the new connection
	 */
	// TODO: link to Dirk's irc.url in docs
	IrcClient connect(string url)
	{
		import std.socket : getAddress, TcpSocket;
		import ssl.socket;
		import ircUrl = irc.url;

		auto info = ircUrl.parse(url);

		auto address = getAddress(info.address, info.port)[0];
		auto af = address.addressFamily;

		auto socket = info.secure? new SslSocket(af) : new TcpSocket(af);

		auto client = new ClientEventHandler(socket, info.channels);

		client.nickName = preferredNick;
		client.userName = userName;
		client.realName = realName;

		client.connect(address);

		eventLoop.add(client);
		eventHandlers ~= client;

		return client;
	}

	/**
	 * Register a command set with the bot.
	 * Params:
	 *    cmdSet = command set to register
	 * See_Also:
	 *    $(DPMODULE command)
	 */
	void registerCommands(ICommandSet cmdSet)
	{
		_commandSets ~= cmdSet;
	}

	/**
	 * Give bot administrator rights to all the users in $(D accountNames),
	 * by account name.
	 *
	 * The account name is the name of the account the user has registered
	 * with the network's authentication services, such as $(D AuthServ) or $(D NickServ).
	 *
	 * Authenticated bot administrators can run commands with the $(D @admin)
	 * command attribute.
	 */
	void addAdmins(Range)(Range accountNames) if(isInputRange!Range && is(ElementType!Range : string))
	{
		auto sortedAdminList = adminList.assumeSorted();

		for(; !accountNames.empty; accountNames.popFront())
		{
			auto newAdmin = accountNames.front;
			auto pivot = sortedAdminList.lowerBound(newAdmin).length;
			adminList.insertInPlace(pivot, newAdmin);
		}
	}

	/// Ditto
	void addAdmins()(string[] accountNames...)
	{
		addAdmins!(string[])(accountNames);
	}

	/**
	 * Convenience method to start an event loop for a bot.
	 *
	 * Same as executing $(D bot.eventLoop._run()).
	 */
	void run()
	{
		eventLoop.run();
	}
}
