module diggler.tracker;

import std.bitmanip : bitfields;

import irc.tracker;

struct UserInfo
{
	mixin(bitfields!(
		bool, "isIdentified", 1,
		bool, "isInvalidated", 1,
		ubyte, "padding", 6
	));
}

alias BotTracker = CustomIrcTracker!UserInfo;
