Triggers: Version 1.2.2 - License: Apache-2
The Swiss Army Knife of performant, instruction-cheap fake events that can be used for pretty much anything!

While triggers are meant to be as semantically equivalent to the EventsAPI as possible, some things do still differ. First of all, functions registered on triggers are not (currently) run in parallel like Event functions are. Triggers have a lot more methods than events to help make managing them much easier, however due to the need for this library to be as performant as poossible a lot of functions don't check early for errors and make heavy use of the Lua feature of elimenating tail calls. Thus error messages that many of these functions give are sometimes not the most informative. This is especially true for ephemeral triggers because they are designed to be ran in tight loops and don't check hardly anything at all in order to save on instructions.
   
In addition, the major difference from events is that triggers do not support the behavior of being able to accept multiple registered functions with the same name. Doing this will error by default if the trigger does not have the override field set to true. If it does however, the new function will just replace the old function. This decision was chosen deliberately because it is usually, at least in my experience, a bug if two functions of the same name are registered on the same event and also disallowing that simplified implementation allowing for a bit more performance. Thus trigger:getRegisteredCount(name) will always return either 0 or 1.

Triggers otherwise work just like events with the addition of the fact that you can call triggers like functions regardless of their events. They also can have arbitrary fields set within them for storing and accessing state and have plenty more methods to make their management simpler.
For example:
  triggers.start_pet(entity)
This would run every function in the START_PET trigger passing them the `entity` as a parameter. This is the most flexible way of using triggers as it circumvents the small amount of automatic setup the library does for the triggers. They are practically free to use!
All triggers can have their functions managed similarly to events. For example running function triggers.start_pet(entity) end and triggers.start_pet:register(function(entity) end) both work the same way the would with events.tick.

TODO:
   * Idle trigger improvements
   * More streamlined ways of doing time-sliced triggers, that only do certain things on each run.
   * Find a way to gain the parallelism that events have.
   * Somehow make managing normal events easier
   * Split the library into the core library providing the API for managing triggers and the anselary library which depends on the core and provides the standard triggers so the core can be used with simpler scripts that don't use a bunch of the standard or if space is a concern.
   * Clean the mess of standard trigger code
   * Check each defined standard trigger for whether it is better to use a direct or normal trigger

Notes about trigger functions:
   Firstly, there are two different types of triggers. Normal triggers and direct triggers. Both types of triggers behave exactly the same when called with trigger:run or called directly, but will differ in behavior when calling trigger:try. The trigger:try method for both types of triggers can take additional arguments from its caller. All predicate functions should expect at a minimum to receive the trigger's table (self) as an argument. When a trigger is being automatically set up on an event. It will inherit the arguments from the calling event when invoking the try method. So a trigger on events.RENDER will receive the render event's delta, context, and matrix arguments, where one on events.TICK will not receive any additional arguments. trigger:try can be run manually at any point and passed any additional arguments. But it will alway take self
   When running normal triggers with trigger:try and when triggers are automatically ran from an event. If there is no predicate function defined, it will simply pass all of its arguments on to return the result of trigger:run. If there is a defined predicate, it will pass all of its arguments to the predicate function. If the trigger is to be ran (the condition is met) then the predicate should return a table containing all arguments that should be passed to each registered function, otherwise it should return no value.
   Direct triggers behave slightly differently. They directly override the trigger:try method with the trigger's predicate. Thus, instead of returning a table of arguments to indicate the condition was met, it should return the result of self:run. It won't and can't stop you from returning some other value if you see fit though.
   Calling a trigger directly as trigger(...) or with trigger:run(...) will skip all checking and are equivalent to eachother. Passing any arguments you call the method with to each of the trigger's registered functions. This does not implicitly include self. If you want it to have access to the trigger itself without having to index it, you should pass self as an argument. E.G. trigger(self,...) or trigger:run(self,...).
   If the trigger has a final function then it will guaranteed run last if the trigger's registered functions are ran. It will not run in any situation where the trigger's registered functions are not ran. This allows triggers to clean up any intermediate state they may have and even return a value if needed. However the caller of the trigger should handle the possibility of receiving nil from a normal trigger when calling any of the trigger's exposed methods.

Each global function should have a comment documenting its behavior above it's annotations. If you find a global function that does not have the comment and proper annotations, that is a problem to either report or if you can figure it out contribute one.
Especially for the annotations since I have not been using an LSP like a maniac.
