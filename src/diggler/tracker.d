module diggler.tracker;

import std.bitmanip : bitfields;

import irc.tracker;

struct UserInfo
{
	mixin(bitfields!(
		bool, "isAdmin", 1,
		ubyte, "padding", 7
	));
}

alias BotTracker = CustomIrcTracker!UserInfo;
