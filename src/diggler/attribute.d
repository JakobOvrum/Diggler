module diggler.attribute;

import std.typetuple : allSatisfy;
import std.traits : isSomeString;

// Command set attributes
struct category
{
	package string value;
}

// Command attributes
struct usage
{
	package string value;
}

struct aliases
{
	package string[] value;

	this(S...)(S aliases) if(allSatisfy!(isSomeString, S))
	{
		this.value = [aliases];
	}
}

struct admin {}

struct channelOnly {}
