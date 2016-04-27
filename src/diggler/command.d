/**
 * Command framework for IRC bots.
 *
 * Groups of commands are bundled as _command sets,
 * which are defined by classes deriving from $(MREF CommandSet).
 *
 * All _command sets implement the $(MREF ICommandSet) interface,
 * which presents basic operations for _command sets.
 *
 * Commands are represented by the $(MREF Command) struct.
 *
 * See_Also:
 *    $(MREF CommandSet)
 */
module diggler.command;

import std.array;
import std.exception;
import std.traits;

import diggler.attribute;
import diggler.bot;
import diggler.context;
import diggler.util;

import irc.client;

/// Can be thrown by command implementations to signal a problem
/// with the command arguments.
class CommandArgumentException : Exception
{
	import irc.util : ExceptionConstructor;
	mixin ExceptionConstructor!();
}

/// Represents a single command.
struct Command
{
	string name;
	string[] aliases;
	string usage;

	static struct ParameterInfo
	{
		string name;
		string typeName;
		string defaultArgument; // null when this parameter has no default argument
		string displayName;

		static immutable angleBrackets = "<>";
		static immutable squareBrackets = "[]";

		this(string name, string typeName, bool optional, string defaultArgument, bool variadic)
		{
			this.name = name;
			this.typeName = typeName;
			this.defaultArgument = defaultArgument;

			auto brackets = optional? squareBrackets : angleBrackets;

			auto app = appender!string();

			app ~= brackets[0];
			app ~= name;

			if(variadic)
				app ~= "...";

			auto isString = typeName == "string";

			if(defaultArgument)
			{
				app ~= " = ";

				if(isString)
					app ~= '\"';

				app ~= defaultArgument;

				if(isString)
					app ~= '\"';
			}

			if(!isString)
			{
				app ~= " (";
				app ~= typeName;
				app ~= ")";
			}

			app ~= brackets[1];

			this.displayName = app.data;
		}
	}

	ParameterInfo[] parameterInfo;
	bool adminOnly = false;
	bool identifiedOnly = false;
	bool channelOnly = false;
	bool variadic = false;

	package:
	void delegate(string strArgs) handler;

	static Command create(alias handler, T)(T dg) if(is(T == delegate))
	{
		alias RetType = ReturnType!T;
		static immutable primaryName = __traits(identifier, handler);

		static assert(is(RetType == void),
			format("return type of command handler `%s` must be `void`, not `%s`",
				fullyQualifiedName!handler,
				RetType.stringof));

		alias Args = FillableParameterTypeTuple!T;
		alias defaultArgs = ParameterDefaultValueTuple!handler;
		enum isVariadic = variadicFunctionStyle!handler == Variadic.typesafe;

		void handleCommand(string strArgs) // TODO: code size reduction potential here
		{
			import std.algorithm : findSplitBefore;
			import std.uni : isWhite; // TODO
			import std.string : strip, stripLeft;

			strArgs = strArgs.strip();

			Args args;

			enum firstDefaultArg = computeFirstDefaultArg!defaultArgs;
			enum hasDefaultArgs = firstDefaultArg != -1;

			static immutable expectedMoreArgsMsg = hasDefaultArgs || isVariadic?
				`got %s argument(s), expected at least %s for command "%s"` :
				`got %s argument(s), expected %s for command "%s"`;

			foreach(i, ref arg; args)
			{
				alias Arg = typeof(arg);
				enum isLastArgument = i == args.length - 1;

				static if(is(Arg == string[]))
				{
					static assert(isLastArgument, fullyQualifiedName!handler ~ `: string[] parameter can only appear at the end of the parameter list`);
					static assert(isVariadic, fullyQualifiedName!handler ~ `: string[] parameter must be variadic`);
				}
				else
					static assert(isValidCommandParameterType!Arg,
						format("parameter #%s of command handler `%s` is of unsupported type `%s`",
							i + 1,
							fullyQualifiedName!handler,
							Arg.stringof));

				alias defaultArg = defaultArgs[i];

				static if(is(defaultArg == void))
				{
					static if(!(isLastArgument && isVariadic)) // Variadic arguments can be empty
						enforceEx!CommandArgumentException(!strArgs.empty,
							format(expectedMoreArgsMsg,
								i,
								hasDefaultArgs? firstDefaultArg : args.length - isVariadic,
								primaryName));
				}
				else
				{
					if(strArgs.empty)
					{
						arg = defaultArg;
					}
				}

				if(!strArgs.empty)
				{
					auto result = strArgs.findSplitBefore(" ");

					auto tail = result[1].stripLeft();

					static if(isLastArgument &&
						(is(Arg : const(char)[]) || is(Arg : const(char[])[])))
					{
						auto rawArg = strArgs;
						strArgs = null;
					}
					else
					{
						auto rawArg = result[0];
						strArgs = tail;
					}

					arg = parseCommandArgument!Arg(rawArg, primaryName, i + 1);
				}
			}

			enforceEx!CommandArgumentException(strArgs.empty,
				format(`too many arguments to command "%s", expected %s`,
					primaryName,
					args.length));

			dg(args);
		}

		Command cmd;
		cmd.name = primaryName;

		static if(isVariadic)
			cmd.variadic = true;

		static if(hasAttribute!(handler, .aliases))
			cmd.aliases = getAttribute!(handler, .aliases).value;

		static if(hasAttribute!(handler, .usage))
			cmd.usage = getAttribute!(handler, .usage).value;

		static if(hasAttribute!(handler, .admin))
			cmd.adminOnly = true;

		static if(hasAttribute!(handler, .identified))
			cmd.identifiedOnly = true;

		static if(hasAttribute!(handler, .channelOnly))
			cmd.channelOnly = true;

		foreach(i, paramName; ParameterIdentifierTuple!handler)
		{
			import std.conv : to;

			alias defaultArg = defaultArgs[i];
			static if(is(defaultArg == void))
			{
				bool optional = false;
				string defaultValue = null;
			}
			else
			{
				bool optional = true;
				static if(isSomeString!(typeof(defaultArg)))
				{
					string defaultValue = defaultArg.ptr? to!string(defaultArg) : null;
				}
				else
					string defaultValue = to!string(defaultArg);
			}

			bool vararg = isVariadic && i == Args.length - 1;
			cmd.parameterInfo ~= ParameterInfo(paramName, commandParameterTypeName!(Args[i]), optional, defaultValue, vararg);
		}

		cmd.handler = &handleCommand;

		return cmd;
	}
}

// TODO: Simplify?
private template computeFirstDefaultArgImpl(int count, args...)
{
	static if(args.length > 0 && is(args[0] == void))
	{
		enum computeFirstDefaultArgImpl = computeFirstDefaultArgImpl!(count, args[1 .. $]) + 1;
	}
	else
		enum computeFirstDefaultArgImpl = count;
}

private template computeFirstDefaultArg(args...)
{
	private enum result = computeFirstDefaultArgImpl!(0, args);
	enum computeFirstDefaultArg = result == args.length? -1 : result;
}

private template commandParameterTypeName(T)
{
	static if(is(T : const(char)[]) || is(T== string[]))
		enum commandParameterTypeName = "string";
	else static if(isIntegral!T)
	{
		static if(isSigned!T)
			enum commandParameterTypeName = "integer";
		else
			enum commandParameterTypeName = "positive integer";
	}
	else static if(isFloatingPoint!T)
		enum commandParameterTypeName = "number";
	else static if(is(T == dchar))
		enum commandParameterTypeName = "character";
	else
		static assert(false);
}

private template isValidCommandParameterType(T)
{
	enum isValidCommandParameterType =
		(!is(T == char[]) && is(T : const(char)[])) ||
		isIntegral!T ||
		isFloatingPoint!T ||
		is(T == dchar);
}

private T parseCommandArgument(T)(string strArg, string cmdName, size_t argNum)
{
	import std.conv : ConvException, parse;

	auto makeError(Exception cause)
	{
		auto msg = format("expected " ~ commandParameterTypeName!T ~ " for argument #%s of command \"%s\", not `%s`",
			argNum,
			cmdName,
			strArg);

		return new CommandArgumentException(msg, __FILE__, __LINE__, cause);
	}

	auto parsedArg = strArg;
	T arg;
	try arg = parsedArg.parse!T();
	catch(ConvException e)
	{
		throw makeError(e);
	}

	enforce(parsedArg.empty, makeError(null));

	return arg;
}

private T parseCommandArgument(T : const(char)[])(string strArg, string cmdName, size_t argNum)
{
	return strArg;
}

private T parseCommandArgument(T : const(char[])[])(string strArg, string cmdName, size_t argNum)
{
	import std.array : split;
	return strArg.split();
}

/**
 * Basic interface of all command sets.
 */
interface ICommandSet
{
	/// Human-readable categorical name for the
	/// commands in the set.
	/// See_Also: $(DPREF attribute, _category)
	string category() @property @safe pure nothrow;

	/**
	 * Context for the currently executing command.
	 * See_Also:
	 *    $(DPREF _context, Context)
	 */
	ref Context context() @property @safe pure nothrow;

	/**
	 * Add the command cmd to the command set.
	 */
	void add(ref Command cmd);

	/**
	 * Lookup a command in this command set by one of its names.
	 */
	Command* getCommand(in char[] cmdName);

	/// Sorted list of the primary names of all commands in the
	/// command set.
	string[] commandNames() @property @safe;
}

/**
 * Base class for command sets.
 *
 * Commands are implemented by adding public, non-static methods
 * to the derived class. Non-public or static methods of the derived
 * class are ignored, as well as methods with the
 * $(DPREF attribute, ignore) attribute.
 *
 * The name of the method becomes the primary name
 * through which the command is invoked in chat. Other names may be added
 * by tagging the method with the $(D @aliases) ($(DPREF attribute, aliases))
 * command attribute. When the command is invoked through one of its
 * names, the method is called.
 *
 * Commands are invoked by sending a message to a channel the bot
 * is a member of, where the message starts with the bot's command prefix
 * followed by the name of the command to invoke. Whitespace-separated words
 * following the command name are parsed as arguments to the command.
 *
 * The arguments to the chat command map one-to-one to the parameters
 * of the method. The method's allowed parameter types are:
 * const or immutable UTF-8 strings, integers and floating point numbers.
 *
 * If the method's last parameter type is a string, then it is passed all the
 * text passed in chat after the previous arguments, including whitespace.
 *
 * If the method's last parameter is an array of strings, then the method
 * must also be marked typesafe-variadic; the array is filled with all
 * whitespace-separated arguments passed after arguments to preceding
 * parameters. If no such arguments are passed, the array is empty.
 *
 * Parameters may have default arguments. If a command invocation does not
 * pass an argument to a parameter with a default argument, the default
 * argument is used instead.
 *
 * If an argument is not passed to a parameter without a default argument,
 * or a non-integer is passed to an integer parameter or a non-number is
 * passed to a floating point parameter, then the bot replies with
 * an error message and the command method is not called.
 *
 * See $(DPMODULE attribute) for a list of attributes that can be attached
 * to command methods to alter the behaviour of the command.
 *
 * This type subtypes a context object ($(DPREF context, Context)) that
 * provides contextual operations and information for
 * use by command method implementations.
 *
 * Params:
 *    T = type with command implementation methods. Must be the derived class
 */
abstract class CommandSet(T) : ICommandSet
{
	private:
	Command[string] _commands;
	string[] _commandNames; // TODO: Not a static, immutable property because of template bugs (2.063)
	Context _context;

	final void registerCommands(T cmdSet)
	{
		foreach(memberName; __traits(derivedMembers, T))
		{
			static if(
				memberName != "__ctor" &&
				memberName != "__dtor" &&
				__traits(compiles, __traits(getMember, T, memberName)) && // ahem...
				__traits(getProtection, __traits(getMember, T, memberName)) == "public" &&
				isSomeFunction!(mixin("T." ~ memberName)) &&
				!__traits(isStaticFunction, mixin("T." ~ memberName)) &&
				!hasAttribute!(mixin("T." ~ memberName), ignore))
			{
				auto dg = &mixin("cmdSet." ~ memberName);
				auto cmd = Command.create!(mixin("T." ~ memberName))(dg);
				add(cmd);
			}
		}
	}

	public:
	this()
	{
		auto cmdSet = enforce(cast(T)this);
		registerCommands(cmdSet);
	}

	// See CommandContext
	//alias context this;

	override: // Implement ICommandSet
	ref Context context()
	{
		return _context;
	}

	string category()
	{
		static if(hasAttribute!(T, .category))
			return getAttribute!(T, .category).value;
		else
			return null;
	}

	void add(ref Command cmd)
	{
		import std.range : assumeSorted, chain;
		import irc.util : values;

		foreach(name; values(cmd.name).chain(cmd.aliases))
			_commands[name] = cmd;

		auto pos = _commandNames.assumeSorted().lowerBound(cmd.name).length;
		_commandNames.insertInPlace(pos, cmd.name);
	}

	Command* getCommand(in char[] cmdName)
	{
		return cmdName in _commands;
	}

	string[] commandNames()
	{
		return _commandNames;
	}
}

/**
 * Temporary workaround for compiler bugs as of DMD front-end version 2.063.
 * This mixin template must be mixed into deriviate classes of $(MREF CommandSet).
 */
// TODO: Temporary, figure out various bugs
mixin template CommandContext()
{
	alias context this;
}
