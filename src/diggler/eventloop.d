module diggler.eventloop;

import irc.eventloop;

private IrcEventLoop _eventLoop = null;

IrcEventLoop defaultEventLoop() @property
{
	if(!_eventLoop)
		_eventLoop = new IrcEventLoop();
	return _eventLoop;
}

static ~this()
{
	if(_eventLoop)
		_eventLoop.destroy();
}
