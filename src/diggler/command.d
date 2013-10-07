module diggler.command;

import std.array;
import std.exception;
import std.traits;

import diggler.attribute;
import diggler.bot;
import diggler.context;
import diggler.util;

import irc.client;

class CommandArgumentException : Exception
{
	import irc.util : ExceptionConstructor;
	mixin ExceptionConstructor!();
}

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
			
			enum firstDefaultArg = computeFirstDefaultArg!(defaultArgs);
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
					enforceEx!CommandArgumentException(!strArgs.empty,
						format(expectedMoreArgsMsg,
							i,
							hasDefaultArgs? firstDefaultArg : args.length,
							primaryName));
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

interface ICommandSet
{
	string category() @property @safe pure nothrow;

	ref Context context() @property @safe pure nothrow;

	void add(ref Command cmd);

	Command* getCommand(in char[] cmdName);

	string[] commandNames() @property @safe;
}

abstract class CommandSet(T) : ICommandSet
{
	private:
	Command[string] _commands;
	string[] _commandNames; // TODO: Not a static, immutable property because of template bugs (2.063)
	Context _context;

	void registerCommands(T cmdSet)
	{
		foreach(memberName; __traits(derivedMembers, T))
		{
			static if(
				memberName != "__ctor" &&
				memberName != "__dtor" &&
				__traits(compiles, __traits(getMember, T, memberName)) && // ahem...
				__traits(getProtection, __traits(getMember, T, memberName)) == "public" &&
				isSomeFunction!(mixin("T." ~ memberName)) &&
				!__traits(isStaticFunction, mixin("T." ~ memberName)))
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

// TODO: Temporary, figure out various bugs
mixin template CommandContext()
{
	alias context this;
}
