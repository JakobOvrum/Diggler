module diggler.context;

import std.array;

import diggler.bot;

import irc.client;
import irc.tracker : IrcChannel, IrcTracker;

struct Context
{
	private:
	Bot _bot;
	Bot.ClientEventHandler client;
	IrcTracker tracker;
	string target;
	IrcUser _user;
	bool isPm;

	public:
	this(Bot _bot, Bot.ClientEventHandler client, IrcTracker tracker, string target, ref IrcUser _user, bool isPm)
	{
		this._bot = _bot;
		this.client = client;
		this.tracker = tracker;
		this.target = target;
		this._user = _user;
		this.isPm = isPm;
	}

	this(Context ctx, string target)
	{
		import irc.protocol : channelPrefixes;
		this = ctx;

		this.target = target;

		switch(target.front)
		{
			foreach(channelPrefix; channelPrefixes)
			case channelPrefix:
				this.isPm = false;
				break;
			default:
				this.isPm = true;
		}
	}

	Bot bot() @property pure nothrow
	{
		return _bot;
	}

	ref const(IrcUser) user() @property pure nothrow
	{
		return _user;
	}

	IrcChannel channel() @property
	{
		if(isPm)
			throw new Exception("not in a channel");

		return tracker[target];
	}

	bool isPrivateMessage() @property pure nothrow
	{
		return isPm;
	}

	void reply(FmtArgs...)(in char[] fmt, FmtArgs fmtArgs)
	{
		client.sendf(target, fmt, fmtArgs);
	}

	void wait(double time)
	{
		auto curFiber = _bot.commandQueue.fiber();

		_bot.eventLoop.post(() {
			_bot.eventLoop.wakeFiber(curFiber);
		}, time);

		curFiber.yield();
	}

	static struct WhoisResult
	{
		IrcUser user;
		string realName;
		string[] channels;
		bool operator = false;
	}

	WhoisResult whois(in char[] nick)
	{
		WhoisResult result;

		auto curFiber = _bot.commandQueue.fiber();

		void onWhoisReply(IrcUser user, in char[] realName)
		{
			if(user.nick == nick)
			{
				result.user = IrcUser(user.nick.idup, user.userName.idup, user.hostName.idup);
				result.realName = realName.idup;
				client.onWhoisReply.unsubscribeHandler(&onWhoisReply);
				_bot.eventLoop.wakeFiber(curFiber);
			}
		}

		client.onWhoisReply ~= &onWhoisReply;

		client.queryWhois(nick);

		curFiber.yield();

		return result;
	}

	version(none) bool isAdmin(in char[] nickName)
	{

	}

	void quit(in char[] msg)
	{
		client.quit(msg);
	}
}
