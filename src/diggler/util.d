/// Utilities not related to the bot framework.
module diggler.util;

string pluralize(string word)(long amount)
{
	static immutable plural = word ~ "s";
	return amount == 1? word : plural;
}

// Attributes
private template isAttribute(Attribute)
{
	enum isAttribute(alias other) = is(typeof(other) == Attribute);
	enum isAttribute(Other) = is(Other == Attribute);
}

template hasAttribute(alias sym, Attribute)
{
	import std.typetuple : anySatisfy;
	enum hasAttribute = anySatisfy!(isAttribute!Attribute, __traits(getAttributes, sym));
}

template getAttribute(alias sym, Attribute)
{
	import std.typetuple : Filter;
	enum getAttribute = Filter!(isAttribute!Attribute, __traits(getAttributes, sym))[0];
}

// From LuaD's `luad.conversions.functions` module
template StripHeadQual(T : const(T*))
{
	alias const(T)* StripHeadQual;
}

template StripHeadQual(T : const(T[]))
{
	alias const(T)[] StripHeadQual;
}

template StripHeadQual(T : immutable(T*))
{
	alias immutable(T)* StripHeadQual;
}

template StripHeadQual(T : immutable(T[]))
{
	alias immutable(T)[] StripHeadQual;
}

template StripHeadQual(T : T[])
{
	alias T[] StripHeadQual;
}

template StripHeadQual(T : T*)
{
	alias T* StripHeadQual;
}

template StripHeadQual(T : T[N], size_t N)
{
	alias T[N] StripHeadQual;
}

template StripHeadQual(T)
{
	alias T StripHeadQual;
}

template FillableParameterTypeTuple(T)
{
	import std.typetuple : staticMap;
	import std.traits : ParameterTypeTuple;
	alias staticMap!(StripHeadQual, ParameterTypeTuple!T) FillableParameterTypeTuple;
}
