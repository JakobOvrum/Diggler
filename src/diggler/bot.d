module diggler.bot;

import core.thread : Fiber;

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

void wakeFiber(IrcEventLoop eventLoop, CommandQueue.CommandFiber fiber)
{
	eventLoop.post(() {
		fiber.resume();
	});
}

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

			bool isPm = target == super.nick;
			auto replyTarget = (isPm? user.nick : target).idup;

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
						debug client.sendf(user.nick, e.toString());
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
	static struct Configuration
	{
		string nick, userName, realName, commandPrefix;
	}

	bool allowPMCommands = true;

	this(Configuration conf, IrcEventLoop eventLoop, string file = __FILE__, size_t line = __LINE__)
	{
		this._eventLoop = eventLoop;

		this.commandPrefix = enforce(conf.commandPrefix, "must specify command prefix", file, line);
		this.preferredNick = enforce(conf.nick, "must specify nick name", file, line);
		this._userName = enforce(conf.userName, "must specify user name", file, line);
		this._realName = enforce(conf.realName, "must specify the real name field", file, line);

		this._commandQueue = new CommandQueue();

		registerCommands(new DefaultCommands(this));
	}

	this(Configuration conf, string file = __FILE__, size_t line = __LINE__)
	{
		import diggler.eventloop : defaultEventLoop;
		this(conf, defaultEventLoop, file, line);
	}

	final:
	IrcEventLoop eventLoop() @property pure nothrow
	{
		return _eventLoop;
	}

	string commandPrefix() const @property pure nothrow
	{
		return _commandPrefix;
	}

	void commandPrefix(string newPrefix) @property pure nothrow
	{
		_commandPrefix = newPrefix;
	}

	string userName() @property pure nothrow
	{
		return _userName;
	}

	string realName() @property pure nothrow
	{
		return _realName;
	}

	auto clients() @property pure nothrow
	{
		return eventHandlers;
	}

	auto commandSets() @property pure nothrow
	{
		return _commandSets;
	}

	void nick(in char[] newNick) @property
	{
		foreach(client; clients)
			client.nick = newNick;
	}

	void nick(string newNick) @property
	{
		foreach(client; clients)
			client.nick = newNick;
	}

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

		client.nick = preferredNick;
		client.userName = userName;
		client.realName = realName;

		client.connect(address);

		eventLoop.add(client);
		eventHandlers ~= client;

		return client;
	}

	void registerCommands(ICommandSet cmdSet)
	{
		_commandSets ~= cmdSet;
	}

	void addAdmins(Range)(Range range) if(isInputRange!Range && is(ElementType!Range : string))
	{
		auto sortedAdminList = adminList.assumeSorted();

		for(; !range.empty; range.popFront())
		{
			auto newAdmin = range.front;
			auto pivot = sortedAdminList.lowerBound(newAdmin).length;
			adminList.insertInPlace(pivot, newAdmin);
		}
	}

	void addAdmins()(string[] accountNames...)
	{
		addAdmins!(string[])(accountNames);
	}

	void run()
	{
		eventLoop.run();
	}
}
