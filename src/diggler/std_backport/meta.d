module diggler.std_backport.meta;
import std.meta : AliasSeq;

/**
 * Sorts a $(LREF AliasSeq) using $(D cmp).
 *
 * Parameters:
 *     cmp = A template that returns a $(D bool) (if its first argument is less than the second one)
 *         or an $(D int) (-1 means less than, 0 means equal, 1 means greater than)
 *
 *     Seq = The  $(LREF AliasSeq) to sort
 *
 * Returns: The sorted alias sequence
 */
template staticSort(alias cmp, Seq...)
{
	static if (Seq.length < 2)
	{
		alias staticSort = Seq;
	}
	else
	{
		private alias bottom = staticSort!(cmp, Seq[0 .. $ / 2]);
		private alias top = staticSort!(cmp, Seq[$ / 2 .. $]);
		alias staticSort = staticMerge!(cmp, Seq.length / 2, bottom, top);
	}
}

///
unittest
{
	alias Nums = AliasSeq!(7, 2, 3, 23);
	enum Comp(int N1, int N2) = N1 < N2;
	static assert(AliasSeq!(2, 3, 7, 23) == staticSort!(Comp, Nums));
}

///
unittest
{
	alias Types = AliasSeq!(uint, short, ubyte, long, ulong);
	enum Comp(T1, T2) = __traits(isUnsigned, T2) - __traits(isUnsigned, T1);
	static assert(is(AliasSeq!(uint, ubyte, ulong, short, long) == staticSort!(Comp,
		Types)));
}

private template staticMerge(alias cmp, int half, Seq...)
{
	static if (half == 0 || half == Seq.length)
	{
		alias staticMerge = Seq;
	}
	else
	{
		private enum Result = cmp!(Seq[0], Seq[half]);
		static if (is(typeof(Result) == bool))
		{
			private enum Check = Result;
		}
		else static if (is(typeof(Result) : int))
		{
			private enum Check = Result <= 0;
		}
		else
		{
			static assert(0, typeof(Result).stringof ~ " is not a value comparison type");
		}
		static if (Check)
		{
			alias staticMerge = AliasSeq!(Seq[0], staticMerge!(cmp, half - 1, Seq[1 .. $]));
		}
		else
		{
			alias staticMerge = AliasSeq!(Seq[half], staticMerge!(cmp, half,
				Seq[0 .. half], Seq[half + 1 .. $]));
		}
	}
}
