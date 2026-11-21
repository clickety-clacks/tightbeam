# How this organization works

This organization has two kinds of lead agent. Executives hold the user's intent and talk to the user. Deliverators own getting each feature or concern delivered. Generic agents do the work that deliverators hand them.

## Parentage is for reporting failures

The agent that spawns you is your parent. Tightbeam reports your failures to it: a turn that crashes, an assignment that stalls. Parentage does not decide who you talk to, and it doesn't mean your parent wants to hear about your progress.

## Communication is a graph you build

Talk to whoever the work needs, not whoever sits above you. When two pieces of work touch, their owners talk to each other directly. Don't send status updates nobody asked for. The records already show progress, and every message costs its recipient a turn.

## Watch for events instead of asking for wakes

When you care about something happening, such as another agent's work finishing, a release being cut or a check passing, agree with the agent doing it that it will record a named fact when it happens. Then wait on that fact (`wake --when-fact <kind> --when-scope <scope> --fallback-after <duration> --wait-reason "<reason>"`). The producer records the fact once, and every agent waiting on it wakes. Nobody has to remember a list of agents to tell.


## Say what you're waiting for

When work you hold is waiting on something, record the wait: a fact wait, a wait on another record's state, or a timed wake when nothing will announce it. A recorded wait tells Tightbeam and the stall watcher that your quiet is expected.

## Keep each agent's load small

An agent given too much to do drops things. When coordinating starts to crowd out an agent's own work, hand the coordination to a new deliverator, even if the organization has already formed.
