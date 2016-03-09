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
import diggler.tracker;

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

	string preferredNick; // Nick can differ across connections
	string _userName;
	string _realName;
	string _commandPrefix;

	package:
	Admin[] adminList; // Sorted

	final class ClientEventHandler : IrcClient // Rename to `Network`?
	{
		BotTracker tracker;
		string[] initialChannels;
		IrcUser[string] adminCache;

		this(Socket socket, string[] initialChannels)
		{
			super(socket);

			this.initialChannels = initialChannels;
			this.tracker = new BotTracker(this);
			this.tracker.start();

			super.onNickChange ~= &invalidate;
			super.onConnect ~= &handleConnect;
			super.onMessage ~= &handleMessage;
		}

		void invalidate(IrcUser user, in char[] nick)
		{
			// mark a user for re-identification if they change nick
			if(auto trackedUser = tracker.findUser(nick))
				trackedUser.payload.isInvalidated = true;
		}

		void handleConnect()
		{
			foreach(channel; initialChannels)
				super.join(channel);
		}

		void handleMessage(IrcUser user, in char[] target, in char[] message)
		{
			import std.string : stripLeft;

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

				bool isPm = target == super.nickName;
				if(isPm && (cmd.channelOnly || !allowPMCommands))
					return;

				// TODO: smarter allocation
				auto cmdArgs = msg.stripLeft().idup;
				auto immNick = user.nickName.idup;
				auto immUser = IrcUser(immNick, user.userName.idup, user.hostName.idup);
				auto replyTarget = isPm? immNick : target.idup;
				auto ctx = Context(this.outer, this, tracker, replyTarget, immUser, isPm);

				commandQueue.post(cmdSet, ctx, () {
					if(cmd.adminOnly && !ctx.isAdmin(immNick) ||
					   cmd.identifiedOnly && !ctx.isIdentified(immNick))
						return;

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

	enum HelpCommand
	{
		none,
		simple,
		categorical
	}

	/**
	 * Create a new bot with the given configuration.
	 *
	 * If $(D eventLoop) is passed, connections by this bot will be handled
	 * by the given event loop. Otherwise, the bot shares a default
	 * event loop with all other bots created in the same thread.
	 */
	this(Configuration conf, HelpCommand help = HelpCommand.categorical, string file = __FILE__, size_t line = __LINE__)
	{
		import diggler.eventloop : defaultEventLoop;
		this(conf, defaultEventLoop, help, file, line);
	}

	/// Ditto
	this(Configuration conf, IrcEventLoop eventLoop, HelpCommand help = HelpCommand.categorical, string file = __FILE__, size_t line = __LINE__)
	{
		this._eventLoop = eventLoop;

		this.commandPrefix = enforce(conf.commandPrefix, "must specify command prefix", file, line);
		this.preferredNick = enforce(conf.nickName, "must specify nick name", file, line);
		this._userName = enforce(conf.userName, "must specify user name", file, line);
		this._realName = enforce(conf.realName, "must specify the real name field", file, line);

		this._commandQueue = new CommandQueue();

		if(help != HelpCommand.none)
			registerCommands(new DefaultCommands(this, help));
	}

	/// Boolean whether or not command invocations are allowed in private messages.
	/// Enabled by default.
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
	 * Params:
	 *    url = URL containing information about server, port, SSL and more
	 *    serverPassword = password to server, or $(D null) to specify no password
	 * Returns:
	 *    the new connection
	 */
	// TODO: link to Dirk's irc.url in docs
	// TODO: try all address results, not just the first
	IrcClient connect(string url, in char[] serverPassword)
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

		client.connect(address, serverPassword);

		eventLoop.add(client);
		eventHandlers ~= client;

		return client;
	}

	/// Ditto
	IrcClient connect(string url)
	{
		return connect(url, null);
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
	 * Represents a bot administrator.
	 *
	 * Authenticated bot administrators can run commands with the $(D @admin)
	 * command attribute.
	 *
	 * Both the nick name and the account name need to match for a user to be
	 * considered an administrator.
	 *
	 * See_Also:
	 *   $(MREF Bot.addAdmins)
	 */
	struct Admin
	{
		/// Nick name of administrator.
		string nickName;

		/**
		 * Account name of administrator.
		 *
		 * The account name is the name of the account the user
		 * has registered with the network's authentication services,
		 * such as $(D AuthServ) or $(D NickServ).
		 */
		string accountName;

		int opCmp(ref const Admin other) const
		{
			import std.algorithm : cmp;
			auto diff = cmp(nickName, other.nickName);
			return diff == 0? cmp(accountName, other.accountName) : diff;
		}
	}

	/**
	 * Give bot administrator rights to all the users in $(D admins).
	 * See_Also:
	 *   $(MREF Bot.Admin)
	 */
	void addAdmins(Range)(Range admins) if(isInputRange!Range && is(Unqual!(ElementType!Range) == Admin))
	{
		for(; !admins.empty; admins.popFront())
		{
			auto sortedAdminList = adminList.assumeSorted!((a, b) => a.accountName < b.accountName);

			Admin newAdmin = admins.front;
			auto accountSearch = sortedAdminList.trisect(newAdmin);
			if(accountSearch[1].empty) // No admin with this account
				adminList.insertInPlace(accountSearch[0].length, newAdmin);
			else
			{
				auto nickSearch = accountSearch[1].release
					.assumeSorted!((a, b) => a.nickName < b.nickName)
					.trisect(newAdmin);

				if(nickSearch[1].empty) // Admin not yet associated with this nick
					adminList.insertInPlace(accountSearch[0].length + nickSearch[0].length, newAdmin);
			}
		}
	}

	/// Ditto
	void addAdmins()(in Admin[] admins...)
	{
		addAdmins!(const(Admin)[])(admins);
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

unittest
{
	Bot.Configuration conf;
	conf.nickName = "test";
	conf.userName = "test";
	conf.realName = "Test";
	conf.commandPrefix = "!";
	auto bot = new Bot(conf);

	bot.addAdmins(Bot.Admin("bNick", "bAccount"));
	assert(bot.adminList == [Bot.Admin("bNick", "bAccount")]);
	bot.addAdmins(Bot.Admin("bNick", "bAccount"), Bot.Admin("aNick", "aAccount"), Bot.Admin("bNick", "bAccount"));
	assert(bot.adminList == [Bot.Admin("aNick", "aAccount"), Bot.Admin("bNick", "bAccount")]);
	bot.addAdmins([Bot.Admin("aNick", "bAccount")]);
	assert(bot.adminList == [Bot.Admin("aNick", "aAccount"), Bot.Admin("aNick", "bAccount"), Bot.Admin("bNick", "bAccount")]);
	bot.addAdmins(Bot.Admin("aNick", "aAccount"));
	assert(bot.adminList == [Bot.Admin("aNick", "aAccount"), Bot.Admin("aNick", "bAccount"), Bot.Admin("bNick", "bAccount")]);
}

