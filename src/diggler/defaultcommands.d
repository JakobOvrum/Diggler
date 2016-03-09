module diggler.defaultcommands;

import diggler.attribute;
import diggler.bot;
import diggler.context;
import diggler.command;

final class DefaultCommands : ICommandSet
{
	Bot bot;
	Context _context;
	alias _context this;
	Command helpCommand;
	Bot.HelpCommand helpConfig;

	this(Bot bot, Bot.HelpCommand helpConfig)
	{
		this.bot = bot;
		this.helpConfig = helpConfig;
		this.helpCommand = Command.create!help(&help);
	}

	@usage("show usage information for commands.")
	void help(string commandName = null)
	{
		import std.array;
		import std.algorithm : filter, map, joiner, reduce, sort;
		import std.range : chain, only, zip;
		import std.format : format;
		import irc.util : values;
		import diggler.util : pluralize;

		if(commandName.empty)
		{
			if(helpConfig == Bot.HelpCommand.simple)
			{
				import std.experimental.allocator : makeArray;
				import std.experimental.allocator.mallocator : Mallocator;
				import std.experimental.allocator.showcase : StackFront;
				StackFront!(2048, Mallocator) alloc;
				reply("Commands: %s", alloc.makeArray!string(bot.commandSets.map!(set => set.commandNames).joiner).sort().joiner(", "));
			}
			else
			{
				auto namedSets = bot.commandSets.filter!(set => set.category);

				foreach(cmdSet; namedSets)
				{
					string[] commands = cmdSet.commandNames;
					if(!commands.empty)
					{
						auto commandList = commands.joiner(", ");
						reply(`%s %s %s: %s`, commands.length, cmdSet.category, pluralize!"command"(commands.length), commandList);
					}
				}

				auto miscCommands = bot.commandSets
					.filter!(set => !set.category)
					.map!(set => cast(string[])set.commandNames);

				auto numCommands = reduce!((sum, cmds) => sum + cmds.length)(0UL, miscCommands);

				if(numCommands != 0)
				{
					auto disambiguation = namedSets.empty? "" : "miscellaneous ";
					reply("%s %s%s: %s", numCommands, disambiguation, pluralize!"command"(numCommands), miscCommands.joiner().joiner(", "));
				}
			}
		}
		else
		{
			foreach(cmdSet; bot.commandSets)
			{
				if(auto cmd = cmdSet.getCommand(commandName))
				{
					auto names = values(cmd.name)
						.chain(cmd.aliases)
						.joiner("|");

					auto paramSummary =
						cmd.parameterInfo.map!(param => param.displayName)
						.joiner(" ");

					immutable description = cmd.usage? cmd.usage : "no description available.";

					static immutable flagList = ["channel", "admin", "identified"];
					string flags;
					auto list = zip(flagList, only(cmd.channelOnly, cmd.adminOnly, cmd.identifiedOnly))
							.filter!(t => t[1])
							.map!(t => t[0]);

					if(!list.empty)
						flags = format(" [%-(%s, %)]", list);
					else
						flags = "";

					reply(`%s %s: %s%s`, names, paramSummary, description, flags);

					return; // Shouldn't be any duplicates
				}
			}

			reply(`The command "%s" does not appear to exist.`, commandName);
		}
	}

	override string category()
	{
		return null;
	}

	override ref Context context()
	{
		return _context;
	}

	override void add(ref Command) {}

	override Command* getCommand(in char[] name)
	{
		return name == "help"? &helpCommand : null;
	}

	override string[] commandNames()
	{
		return null;
	}
}
