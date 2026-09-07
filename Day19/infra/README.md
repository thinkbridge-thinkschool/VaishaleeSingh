# Day19/infra

`servicebus.bicep` used to live here. It was written on Day 19 for the topics /
DLQ exercise and then never referenced by anything — a template describing a
topology that no deployment ever created.

Day 23 moved it into the deployment graph and parameterized it:

    Day7/piece2/infra/modules/servicebus.bicep

It is a move, not a copy. Two divergent Service Bus templates in one repository
is the exact failure mode the Day 23 exercise is about, so this file is gone
rather than left behind as a second source of truth. The Day 19 write-up in
`../docs/` still describes the topology, and its reasoning is preserved verbatim
in the comments of the module.
