module diggler.commandqueue;

final class CommandQueue
{
	import core.thread : Fiber;

	import std.algorithm;
	import std.array;
	import std.exception : enforce;
	debug(CommandQueue) import std.stdio;

	import diggler.context;
	import diggler.command;

	private: // TODO: use std.container.Array?
	static struct Task
	{
		ICommandSet cmdSet;
		Context context;
		void delegate() entryPoint;

		void prepare()
		{
			cmdSet.context = context;
		}
	}

	Task[] queue;
	CommandFiber[] fibers;

	public:
	class CommandFiber : Fiber
	{
		import std.typecons : Nullable;
		Nullable!Task currentTask;
		bool ready = true;

		void run() // Never to be called directly
		{
			ready = false;
			scope(exit) ready = true;

			if(!currentTask.isNull) // Can be set directly before calling fiber
			{
				currentTask.prepare();
				currentTask.entryPoint();
			}

			while(!queue.empty)
			{
				auto task = queue.front;
				queue.popFront();

				currentTask = task;
				task.prepare();
				task.entryPoint();
			}
		}

		void resume()
		{
			debug(CommandQueue) writefln("resuming a fiber %s %s", fibers.map!(fiber => fiber.state).array, fibers.map!(fiber => fiber.ready).array);
			if(state == State.HOLD)
			{
				currentTask.prepare();
				call();
			}
		}

		this()
		{
			super(&run);
		}
	}

	this(size_t numFibers = 4)
	{
		fibers = new CommandFiber[](numFibers);

		foreach(ref fiber; fibers) // TODO: grow lazily up to a max?
			fiber = new CommandFiber();
	}

	CommandFiber fiber() @property
	{
		return enforce(cast(CommandFiber)Fiber.getThis());
	}

	void post(ICommandSet cmdSet, Context ctx, void delegate() cb)
	{
		auto task = Task(cmdSet, ctx, cb);

		import std.stdio;

		auto availableFibers = fibers.find!(fiber => fiber.ready)();//fibers.find!(fiber => fiber.state == Fiber.State.TERM);
		if(!availableFibers.empty)
		{
			debug(CommandQueue) writefln("Found available fiber (#%s), running command right away %s", fibers.length - availableFibers.length + 1,
					 fibers.map!(fiber => fiber.ready).array);
			auto availableFiber = availableFibers.front;
			availableFiber.currentTask = task;
			availableFiber.reset();
			availableFiber.call();
		}
		else
		{
			queue ~= task;
			debug(CommandQueue) writeln("no available fiber, queued command");
		}
	}
}
