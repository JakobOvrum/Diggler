module diggler.attribute;

import std.typetuple : allSatisfy;
import std.traits : isSomeString;

// TODO: Use constructor functions for nicer documentation?

// Command set attributes
/**
 * Command set attribute.
 *
 * Apply to a deriviate class of $(DPREF command, CommandSet)
 * to set its categorical name.
 */
struct category
{
	package string value;
}

// Command attributes
/**
 * Command attribute.
 *
 * Apply to a command method to provide a description for the command.
 */
struct usage
{
	package string value;
}

/**
 * Command attribute.
 *
 * Apply to a command method to provide alternative names for a command,
 * that can be used to invoke it in chat.
 */
struct aliases
{
	package string[] value;

	this(S...)(S aliases) if(allSatisfy!(isSomeString, S))
	{
		this.value = [aliases];
	}
}

/**
 * Command attribute.
 *
 * Command methods with this attribute can only be invoked by
 * bot administrators. Apply to commands that should only be
 * usable by trusted users.
 * See_Also:
 *    $(DPREF bot, Bot.addAdmins)
 */
struct admin {}

/**
 * Command attribute.
 *
 * Methods with this attribute can only be called by a user
 * that is registered with services, meaning they are the
 * owner of that particular nickname.
 */
struct identified {}

/**
 * Command attribute.
 *
 * Commands for command methods with attribute cannot be
 * invoked in private messages, regardless of the
 * value of the $(DPREF bot, Bot.allowPMCommands) property.
 */
struct channelOnly {}

/**
 * Command attribute.
 *
 * Methods with this attribute are not treated as commands
 * even if they are public.
 */
struct ignore {}
