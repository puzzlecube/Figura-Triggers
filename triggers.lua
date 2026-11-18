--[=====[ Triggers: Version 1.2.3 - License: Apache-2
   The Swiss Army Knife of performant, instruction-cheap fake events.

   While triggers are meant to be as semantically equivalent to the EventsAPI as possible, some things do still differ. First of all, functions registered on triggers currently have an order which they run given by the order they are registered while event functions don't seem to have any order. Triggers have a lot more methods than events to help make managing them much easier, however due to the need for this library to be as performant as poossible a lot of functions don't check early for errors and make heavy use of the Lua feature of elimenating tail calls. Thus error messages that many of these functions give are sometimes not the most informative. This is especially true for ephemeral triggers because they are designed to be ran in tight loops and don't check anything at all in order to save on instructions.
   
   In addition, the major difference from events is that triggers do not support the behavior of being able to accept multiple registered functions with the same name. Doing this will error by default if the trigger does not have the override field set to true. If it does however, the new function will just replace the old function. This decision was chosen deliberately because it is usually, at least in my experience, a bug if two functions of the same name are registered on the same event and also disallowing that simplified implementation allowing for a bit more performance. Thus trigger:getRegisteredCount(name) will always return either 0 or 1.

   Triggers otherwise semantically work just like events with the addition of the fact that you can call triggers like functions regardless of their events. They also can have arbitrary fields set within them for storing and accessing state and have plenty more methods to make their management simpler.
   For example:
     triggers.start_pet(entity)
   This would run every function in the START_PET trigger passing them the `entity` as a parameter. This is the most flexible way of using triggers as it circumvents the small amount of automatic setup the library does for the triggers. They are practically free to use!
   All triggers can have their functions managed similarly to events. For example running function triggers.start_pet(entity) end and triggers.start_pet:register(function(entity) end) both work the same way the would with events.tick.

   TODO:
   * Idle trigger improvements
   * More streamlined ways of doing time-sliced triggers, that only do certain things on each run.
   * Ordered vs unordered triggers
   * Somehow make managing normal events easier
   * Split the library into the core library providing the API for managing triggers and the anselary library which depends on the core and provides the standard triggers so the core can be used with simpler scripts that don't use a bunch of the standard or if space is a concern.
   * Clean the mess of standard trigger code
   * Check each defined standard trigger for whether it is better to use a direct or normal trigger
]=====]

local events = events

local m = {
}

-- All registered triggers
local triggersAPI = {}

local _m = {
   __name = "TriggersAPI",
   __type = "TriggersAPI",
   __index = function(self,key)
      return rawget(triggersAPI, (type(key) == 'string' and string.upper(key)) or key) or rawget(m,key)
   end
}

-- Lookup table to deny setting these indexes of triggers because doing so could easily cause inconsistancy.
local _trigger_proto = {
   name = true,
   event = true,
   funcs = true,
   names = true,
   predicate = true,
   final = true,
   try = true,
   run = true,
}

-- Metatable of each trigger
local trigger = {
   __name = 'Trigger',
   __type = 'Trigger',
   __newindex = function(self,k,v)
      if _trigger_proto[k] then
	 error('Attempt to override immutable field '..k)
      end
      return rawset(self,k,v)
   end
}

--[[ A note about trigger functions:
   Firstly, there are two different types of triggers. Normal triggers and direct triggers. Both types of triggers behave exactly the same when called with trigger:run or called directly, but will differ in behavior when calling trigger:try. The trigger:try method for both types of triggers can take additional arguments from its caller. All predicate functions should expect at a minimum to receive the trigger's table (self) as an argument. When a trigger is being automatically set up on an event. It will inherit the arguments from the calling event when invoking the try method. So a trigger on events.RENDER will receive the render event's delta, context, and matrix arguments, where one on events.TICK will not receive any additional arguments. trigger:try can be run manually at any point and passed any additional arguments. But it will alway take self
   When running normal triggers with trigger:try and when triggers are automatically ran from an event. If there is no predicate function defined, it will simply pass all of its arguments on to return the result of trigger:run. If there is a defined predicate, it will pass all of its arguments to the predicate function. If the trigger is to be ran (the condition is met) then the predicate should return a table containing all arguments that should be passed to each registered function, otherwise it should return no value.
   Direct triggers behave slightly differently. They directly override the trigger:try method with the trigger's predicate. Thus, instead of returning a table of arguments to indicate the condition was met, it should return the result of self:run. It won't and can't stop you from returning some other value if you see fit though.
   Calling a trigger directly as trigger(...) or with trigger:run(...) will skip all checking and are equivalent to eachother. Passing any arguments you call the method with to each of the trigger's registered functions. This does not implicitly include self. If you want it to have access to the trigger itself without having to index it, you should pass self as an argument. E.G. trigger(self,...) or trigger:run(self,...).
   If the trigger has a final function then it will guaranteed run last if the trigger's registered functions are ran. It will not run in any situation where the trigger's registered functions are not ran. This allows triggers to clean up any intermediate state they may have and even return a value if needed. However the caller of the trigger should handle the possibility of receiving nil from a normal trigger when calling any of the trigger's exposed methods.
]]

-- Register a new function onto a trigger just like you can register one onto an event. Note that
--@param self Trigger
--@param func function
--@param name string?
--@return self
function trigger:register(func, name)
   if name == nil then name = #self.names+1 end
   local event = self.event
   if not self.override then
      for k,n in ipairs(self.names) do
	 if n == name then
	    error(self.name..' already has a registered function named '..name..' at index '..k..': function '..tostring(self.funcs[k]))
	 end
      end
   end
   table.insert(self.funcs,func)
   table.insert(self.names,name)
   local tname = 'trigger:'..self.name
   if event and event:getRegisteredCount(tname)==0 then
      event:register(function(...) return self:try(...) end,tname)
   end
   return self
end

-- Remove an entry from the trigger and optionally if applicable update the event it is associated with.
--@param self Trigger
--@param name string
--@param noUpdate boolean?
--@return self
function trigger:remove(name,noUpdate)
   for k,v in ipairs(self.names) do
      if v == name then
	 table.remove(self.funcs,k)
	 table.remove(self.names,k)
      end
   end
   if self.event and #self.names == 0 and not noUpdate and not self.alwaysRegistered then
      self.event:remove('trigger:'..self.name)
   end
   return self
end

-- Clear the trigger's functions. If noUpdate is not set, then it will also un-register the trigger from it's parent event/trigger if any.
--@param self Trigger
--@param noUpdate boolean?
--@return self
function trigger:clear(noUpdate)
   self.funcs={}
   self.names={}
   if self.event and not noUpdate then
      self.event:remove('trigger:'..self.name)
   end
   return self
end

-- Try to run a trigger by checking its predicate and if successful, run it. This is how triggers are automatically ran from events.
--@param self
--@return any?
function trigger:try(...)
   if not self.predicate then
      return self:run(...)
   end
   local args = self:predicate(...)
   if args then
      return trigger.run(self,table.unpack(args))
   end
end

-- Run a trigger regardless of its predicate passing any arguments (except the self used to call the method) to each registered function. This is useful for calling triggers from other events or calling them like regular functions. Note that this can easily be a footgun if you directly run triggers that are registered with m.newIf.
--@param self Trigger
function trigger:run(...)
   for _,fn in ipairs(self.funcs) do
      fn(...)
   end
   if self.final then
      return self:final(...)
   end
   return
end

trigger.__index = trigger
-- This will allow you to call trigger:run by implicitly calling your trigger.
trigger.__call = trigger.run

-- Return if the trigger is being set up and ran on an event. Note that this does not return true just because you call the trigger from an arbitrary event. It must be set up with it as a parent.
--@param self Trigger
--@return boolean
function trigger:hasEvent()
   return self.event == nil
end
-- Get the trigger's event
--@param self Trigger
--@return Event|Trigger?
function trigger:getEvent()
   return self.event
end

-- Return whether the trigger has a predicate
--@param self Trigger
--@return boolean
function trigger:hasPredicate()
   return self.predicate ~= nil
end
trigger.isConditional = trigger.hasPredicate

-- Return the trigger's predicate
--@param self Trigger
--@return function
function trigger:getPredicate()
   return self.predicate
end
trigger.getCondition = trigger.getPredicate

-- Return the names of the trigger's functions
--@param self Trigger
--@return table of strings
function trigger:getNames()
   return self.names
end

-- Return the list of the trigger's functions
--@param self
--@return table of functions
function trigger:getFunctions()
   return self.funcs
end

-- Get all registered functions for this trigger. Returns a table mapping the function names to their definitions followed by the trigger's final function if present.
--@param self
--@return table<string,function>,function?
function trigger:getRegistered()
   local names = self.names
   local funcs = self.funcs
   local out = {}
   for i,name in ipairs(names) do
      out[name]=funcs[i]
   end
   return out,self.final
end

-- Return the trigger's final function
--@param self Trigger
--@return function?
function trigger:getFinalizer()
   return self.final
end

-- Return a function from the list of trigger functions if it exists. Followed by it's name and the index it is registered at.
--@param self Trigger
--@param index number|string
--@return function?,string?,number?
function trigger:getFunction(index)
   local names = self.names
   local funcs = self.funcs
   local name = nil
   local num = nil
   if type(name) == 'number' then
      name = names[index]
      num = index
   else
      name = index
      for n,fname in ipairs(names) do
	 if fname == index then
	    num = n
	    break
	 end
      end
   end
   if name and num then
      return funcs[num],name,num
   end
   return nil
end

-- Get the trigger's event function if any. Returns nil if the trigger has no event. Returns false followed by its event if it has an event but the event function to run the trigger isn't registered. Returns true followed by the event and the name of the function if it is set up to an event function. This method should be considered overridable if you are doing something more manual.
--@param self Trigger
--@return boolean,Event|Trigger?,string?
function trigger:getSetOn()
   if not self.event then return nil end
   if self.event:getRegisteredCount('trigger:'..self.name) > 0 then
      print(self.event)
      return true, self.event, 'trigger:'..self.name
   end
   return false, self.event
end

-- Return whether or not this is a direct trigger
--@return boolean
function trigger:isDirect()
   if rawget(self,'try') then
      return true
   end
   return false
end

-- Return whether or not this trigger is always registered to its event
--@return boolean
function trigger:isAlwaysRegistered()
   return self.alwaysRegistered
end

-- If a name is given, get whether or not a function with that name is registered on the trigger. Unlike this method for events, this will only return 0 or 1 to be compatible. If there is no name given it will return a count of how many functions are registered on the trigger.
--@param self Trigger
--@param name string?
--@return number
function trigger:getRegisteredCount(name)
   if name ~= nil then
      local names = self.names
      for _,thisname in ipairs(names) do
	 if thisname == name then
	    return 1
	 end
      end
      return 0
   end
   return #self.names
end

-- Register a new trigger. Note that all functions registered to the trigger receive their arguments from the return value of the predicate OR the arguments specified when calling the trigger:run method or the trigger itself. Running through trigger:try effectively passes arguments to the predicate like an event funciton would
--@param name string
--@param event Event|Trigger? If this is set, it will automatically be added to the event or trigger.
--@param first function(self,...)? If present this function must return nil or nothing to indicate that the trigger should not run, or a table containing the values you want to pass to the trigger's functions to indicate it should run. This is ran when the trigger is first tried either from an event or with trigger:try. While it is technically not wrong to register a trigger with an event but no predicate, you would probably be better off just calling that event directly or creating an alias to save on instructions if all you care about is declaring intent.
--@param final function(self,...)|table? If this is a table and the vars argument is nil then its value is moved to the vars argument leaving this argument nil. If it is a function then this is the function ran after all registered trigger functions have ran. This can be used to have the trigger return a value and save information for the next run
--@param vars table? Other state variables initial values. They must not conflict with the standard pre-defined fields. There are two special keys that can be in this table. alwaysRegistered and isDirect. alwaysRegistered ensures that if there is an event associated with it, then the event will always have a function that runs trigger:try on it regardless of if the trigger has no body functions. If isDirect is true, then the parameter first becomes this trigger's trigger:try method instead of its predicate and designates the trigger a direct trigger.
--@return Trigger
function m.new(name,event,first,final,vars)
   name = string.upper(name)
   -- Backwards compatibility with the old API but it is also convenient
   if final and type(final) ~= 'function' then
      vars = final
      final = nil
   end
   local this = {
      name = name,
      event = event,
      names = {},
      funcs = {},
      final = final,
      override = false,
   }
   if type(vars) == 'table' then
      if vars.isDirect then
	 vars.isDirect=nil
	 this.try = first
	 for k,v in pairs(vars) do
	    if this[k] then
	       error('Attempt to override direct trigger field '..k..' with state variable '..tostring(v))
	    elseif not event and k == 'alwaysRegistered' then
	       error('Attempt to keep a trigger with no event always registered to an event')
	    end
	    this[k]=v
	 end
      elseif event then
	 this.predicate = first
	 for var,val in pairs(vars) do
	    if _trigger_proto[var] and var ~= 'alwaysRegistered' then
	       error('Attempted to override immutable trigger field '..var..' while registering trigger')
	    end
	    this[var]=val
	 end
      else
	 this.predicate = first
	 for var,val in pairs(vars) do
	    if _trigger_proto[var] then
	       error('Attempted to override immutable trigger firld '..var..' while registering trigger')
	    end
	 end
      end
   else -- The non-table variants mostly exist for backwards compatibility
      this.predicate = first
      this.state = vars
   end
   setmetatable(this,trigger)
   if this.alwaysRegistered then
      event:register(function(...) return this:try(...) end,'trigger:'..name)
   end
   rawset(triggersAPI,name,this)
   return this
end

-- Register a trigger which is only set up on an event if the given condition is true. Otherwise it registers an eventless dummy version so it is usable if necessary outside the given context. This isn't strictly necessary, but it is a bit clearer than using just new but anding the event with a condition.
--@param name string
--@param condition any If it is a function it must take 0 arguments. Otherwise it is just checked for truthiness
--@param event Event|Trigger
--@param first function(self,...)?
--@param final function(self,...)|table? if it is a table and the vars field is empty this data will represent that field
--@param vars table
--@return Trigger
function m.newIf(name,condition,event,first,final,vars)
   if not event then
      error("Attempt to conditionally create a trigger with no event to assign it to when the precondition is true")
   end
   if (type(condition) == 'function' and condition()) or condition then
      return m.new(name,event,first,final,vars)
   end
   return m.new(name,nil,first,final,vars)
end

-- Create 3 new triggers, one to run at the start of when the predicate returns true, one the whole time, and one to run when the predicate stops returning true.
--@param name string  Name of the main trigger
--@param event Event|Trigger
--@param predicate function(self,...)
--@param final function(self)?
--@param starter string? Name of the trigger ran at the start of the predicate returning true. Defaults to 'START_'..name
--@param stopper string? Name of the trigger ran at the end of the predicate returning true. Defaults to 'STOP_'..name
--@return Trigger,Trigger,Trigger
function m.newSequence(name,event,predicate,final,starter,stopper)
   if not predicate then
      error('Trigger sequence '..name..' requires a predicate function')
   elseif not event then
      error('Trigger sequence '..name..' must be associated with an event')
   end
   if starter == nil then
      starter = 'START_'..name
   end
   if stopper == nil then
      stopper = 'STOP_'..name
   end
   -- the start and stop triggers have no event because they are ran from the predicate in a mildly hasky display of insanity and thus technically inherit their event
   local start = m.new(starter)
   local stop = m.new(stopper)
   local this
   local try = function(self,...)
      local now = predicate(self,...)
      if now == nil then
	 if self.state then
	    stop(...)
	    self.state = false
	 end
	 return
      end
      if not self.state then
	 start(...)
	 self.state = true
      end
      self(...)
   end
   return m.new(name,event,try,final,
		{state=false,
		 starter=start,
		 stopper=stop,
		 isDirect=true,
		 alwaysRegistered=true}),start,stop
end

-- Create a new trigger copying all data from a pre-existing trigger and overriding the specified fields.
--@param new string
--@param from string|Trigger|Event Strings will result in the old trigger being looked up in the table of registered triggers. Trying to derive a trigger from an event will either result in just creating a new trigger as normal or an error if the tied field is set because Event.__newindex does not track the registered functions in nearly the same way
--@param event Event|Trigger?
--@param first function(self, ...)
--@param final function(self)?: Unlike m.new and m.newIf, this does not support putting anything but a function or nil in this field
--@param vars any?
--@param tied boolean: If this is set, the functions from the old trigger will be tied to the new one and registering a function on the old one will register a function on the new one and vice versa. Otherwise it is a blank slate that iis unaffected by the old trigger.
--@return Trigger
function m.derive(new,from,event,first,final,vars,tied)
   local old = from
   local ftype = type(from)
   if ftype == 'string' then
      old = triggersAPI[from]
   elseif ftype == 'Event' then -- This is just a trigger definition
      if tied then
	 return error("Can't meaningfully derive a tied trigger from an event because the event's functions can not be queried")
      end
      return m.new(name,event,first,final,vars)
   elseif ftype ~= 'Trigger' then
      return error('Attempt to derive a trigger from '..tostring(ftype))
   end
   if not old then
      return error('Attempt to derive a trigger from a nonexistant trigger')
   end
   local names,funcs
   if tied then
      names,funcs = old.names,old.funcs
   else
      names,funcs = {},{}
   end
   local this = {
      name = name,
      event = event,
      names = names,
      funcs = funcs,
      predicate = first or old.predicate,
      final = final or old.final,
   }
   if type(vars) == 'table' then
      for k,v in pairs(vars) do
	 this[k]=v
      end
   else
      this.state = vars
   end
   if tied then
      for k,v in pairs(old) do
	 if not (_trigger_proto[k] or this[k]) then
	    this[k]=v
	 end
      end
   end
   setmetatable(this,trigger)
   rawset(triggersAPI,name,this)
   return this
end

-- Conditional form of m.derive to match m.newIf. Additionally takes a condition as the second argument that only sets the event if it is not false
--@param new string
--@param from string|Trigger|Event Strings will result in the old trigger being looked up in the table of registered triggers. Trying to derive a trigger from an event will either result in just creating a new trigger as normal or an error if the tied field is set because Event.__newindex does not track the registered functions in nearly the same way
--@param event Event|Trigger?
--@param first function(self, ...)
--@param final function(self)? Unlike m.new and m.newIf, this does not support putting anything but a function or nil in this field
--@param vars any?
--@param tied boolean If this is set, the functions from the old trigger will be tied to the new one and registering a function on the old one will register a function on the new one and vice versa. Otherwise it is a blank slate that iis unaffected by the old trigger.
--@return Trigger
function m.deriveIf(name,condition,event,first,final,vars,tied)
   if not event then
      error("Attempt to conditionally create a trigger with no event to assign it to when the precondition is true")
   end
   if (type(condition) == 'function' and condition()) or condition then
      return m.derive(name,event,first,final,vars,tied)
   end
   return m.derive(name,nil,first,final,vars,tied)
end

-- Create an alias for a trigger or event. Note that aliasing an event does not create a trigger. This is the only thing that can potentially cause events to exist in the trigger api, but is there is you really need that performance.
--@param name string
--@param from Event|Trigger
--@return Event|Trigger
function m.alias(name,from)
   name = name:upper()
   if type(from) == 'string' then
      from = triggersAPI[from]
   end
   if type(from) ~= 'Event' and type(from) ~= 'Trigger' then
      error('Attempt to create a trigger alias of '..type(from))
   end
   rawset(triggersAPI,name,from)
   return triggersAPI[name]
end

-- Get all registered triggers. This is to be congruent with EventsAPI
--@return TriggersAPI
function m.getTriggers()
   return triggersAPI
end

--[[ Ephemeral triggers:
   These allow for scheduling one-shot code to run at at a later time using a parent event and removing the code from the event once it is ran
   A word of warning: These probably will give terrible error messages because of tail call elimination which is used to keep instructions down. Make sure the event or trigger exists
]]

-- Keep track of ephemeral triggers so we can avoid name collisions
local ephemerals = 0

-- Queue up a function to be ran the next time the given event or trigger is ran. This function will remove itself after it finishes.
--@param event Event|Trigger
--@param func function(...)
--@param name string?
function m.onNext(event,func,name)
   ephemerals=ephemerals+1
   if not name then
      name = 'ephemeral:'..client:intUUIDToString(client.generateUUID())
   end
   return event:register(function(...)
	 ephemerals=ephemerals-1
	 event:remove(name)
	 -- Keep this in tail call position
	 return func(...)
   end,name)
end

-- Queue up a list of functions to run on subsequent occurances of the given event
--@param event Event|Trigger
--@param funcs table<function(...)>
--@param name string?
function m.queueNext(event,funcs,name)
   ephemerals=ephemerals+1
   if not name then
      name = 'ephemeral:'..client:intUUIDToString(client.generateUUID())
   end
   local i,q = 1,#funcs
   -- Doing it such that the queue function unregisters itself one run after the last element helps make sure the instruction count doesn't slightly spike on the last invocation. Even if that is only about 2 instructions.
   return event:register(function(...)
	 if i > q then
	    ephemerals=ephemerals-1
	    event:remove(name)
	 else
	    local func = funcs[i]
	    i=i+1
	    return func(...)
	 end
   end,name)
end

-- Queue up a function to run the next time the event or trigger is called until it returns a truthy value. When it returns a truthy value the function will remove itself
--@param event Event|Trigger
--@param func function(...) returning a boolean
--@param ignoreNil boolean? if this is set, the function returning nil or not returning at all will not signal an error. This exists to prevent accidentally making very non-ephemeral ephemeral triggers
--@param name string?
function m.onNextUntil(event,func,ignoreNil,name)
   ephemerals=ephemerals+1
   if not name then
      name = 'ephemeral:'..client:intUUIDToString(client.generateUUID())
   end
   if not ignoreNil then
      return event:register(function(...)
	    local v = func(...)
	    if v == nil then
	       error('Missing return value from ephemeral trigger '..name)
	    end
	    if v then
	       ephemerals=ephemerals-1
	       event:remove(name)
	    end
      end,name)
   end
   return event:register(function(...)
	 if func(...) then
	    ephemerals=ephemerals-1
	    event:remove(name)
	 end
   end,name)
end

-- Queue up a function to be ran the next time during the given event, the given predicate returns true. Then automatically remove this function from the event. If withResult is true, the result of the predicate will be the first argument to the function
--@param event Event|Trigger
--@param pred function(...)
--@param withResult boolean?
--@param name string?
function m.whenNext(event,pred,func,withResult,name)
   ephemerals=ephemerals+1
   if not name then
      name = 'ephemeral:'..client:intUUIDToString(client.generateUUID())
   end
   if withResult then
      return event:register(function(...)
	    local p = pred(...)
	    if p then
	       ephemerals=ephemerals-1
	       event:remove(name)
	       return func(p,...)
	    end
      end,name)
   else
      return event:register(function(...)
	    local p = pred(...)
	    if p then
	       ephemerals=epehemerals-1
	       event:remove(name)
	       return func(...)
	    end
      end,name)
   end
end

-- Run this function for the next n instances of the event or trigger. The timer is passed as the first argument of the function.
--@param n number
--@param event Event|Trigger
--@param func function(timer: number,...)
--@param name string?
function m.forTheNext(n,event,func,name)
   if not name then
      name = 'ephemeral:'..client:intUUIDToString(client.generateUUID())
   end
   local i = 1
   ephemerals=ephemerals+1
   return event:register(function(...)
	 if i == n then
	    ephemerals=ephemerals-1
	    event:remove(name)
	    return func(n,...)
	 end
	 i=i+1
	 return func(i,...)
   end,name)
end
   

-- Run the given function on the next time the event is called after the timer reaches zero
--@param event Event
--@param delay number
--@param func function(...)
--@param name string?
function m.onNextAfter(event,delay,func,name)
   --[[if delay<=0 or delay%1 ~= 0 then
      error('Timer must be an integer greater than 0')
      end]]
   ephemerals=ephemerals+1
   if not name then
      name = 'ephemeral:'..client:intUUIDToString(client.generateUUID())
   end
   return event:register(function(...)
	 if delay > 0 then
	    delay = delay-1
	    return
	 end
	 ephemerals=ephemerals-1
	 event:remove(name)
	 return func(...)
   end,name)
end

-- Get the amount of ephemeral functions being ran (created via m.onNext
--@return number
function m.ephemeralCount()
   return ephemerals
end

--[[ Standard triggers:
   This provides a unified implementation of certain common tasks that can be relied on (with some checking) in libraries.
]]

-- For conditional standard triggers that require a host-only context since several use that condition
local hostp = host:isHost()

--This table contains tables corresponding to the name, event, and predicate of entries. Unfortunately things like if we are dead or respawning and pose changes aren't included because they need to track another variable that holds their previous state.
local standardTriggers = {
   -- Triggers specifically when your pose changes. The previous pose is stored in the trigger's state to be passed for the next time the trigger runs
   POSE_CHANGE = {events.TICK,
		  function(self)
		     self.pose = player:getPose()
		     if self.pose == self.prev then
			return
		     end
		     return {self.prev,self.pose}
		  end,
		  function(self)
		     self.prev = self.pose
		  end,
		  vars={prev='STANDING'}},
   DIMENSION_CHANGE = {events.TICK,
		       function(self)
			  self.dimension = player:getDimensionName()
			  if self.dimension == self.prev then
			     return
			  end
			  return {self.prev,self.dimension}
		       end,
		       function(self)
			  self.prev = self.dimension
   end},
   -- Triggers once when the player dies. TODO: Add deliberating on damage type to this sequence
   DEATH = {events.TICK, function(self)
	       return (not player:isAlive() and player:getDeathTime()==0) and {}
   end},
   -- When the player respawns
   RESPAWN = {events.TICK, function(self)
		 local alive = player:isAlive()
		 local run = alive and self.state
		 self.state = not alive
		 return run and {}
   end,false},
   -- Triggers each tick when the player is dead
   DEAD = {events.TICK, function()
	      if player:isAlive() and self.state then
		 triggers.RESPAWN()
		 self.state = false
		 return
	      end
	      if not self.state then
		 self.state = true
		 triggers.DEATH()
	      end
	      return {player:getDeathTime()}
   end,false,needs={"DEATH","RESPAWN"}},
   -- More precise than events.USE_ITEM
   TICK_USE_ITEM = {events.TICK, function(self)
		       local itm = player:getActiveItem()
		       local run = itm and itm~=self.state
		       self.state = itm
		       return run and {itm}
   end},
   -- Runs in every context except first person and shaders
   SECOND_PERSON_RENDER = {events.RENDER, function(self,d,ctx,mat)
			      if ctx == 'FIRST_PERSON' or ctx == 'OTHER' then return end
			      return {d,ctx,mat}
   end},
   -- This one is special because it will render for your avatar only once per frame. If this is the host it renders in FIRST_PERSON, otherwise in RENDER.
   AVATAR_RENDER = {events.RENDER},
   -- Ran while not moving
   IDLE = {events.TICK, function(self,time)
	      --local v = player:getVelocity()==vec(0,0,0)
	      if player:isMoving() then
		 self.time = 0
		 return
	      end
	      local t = self.time
	      self.time = self.time+1
	      --if host:isHost() then print('idling '..self.time) end
	      return {t}
   end, {time=0}},
   -- The fact that since these can each be set up independently is mildly unfortunate maintenance wise
   DISMOUNT = {events.TICK, function(self)
		  local v = player:getVehicle()
		  if v then
		     self.state = v
		     return
		  end
		  if self.state then
		     local pv = self.state
		     self.state = nil
		     return {pv}
		  end
		  return
   end, needs={'MOUNT'}},
   RIDE = {events.TICK, function(self)
	      if player:getVehicle()==nil then
		 self.state = false
		 return
	      elseif plaeyr:getControlledVehicle()==nil then
		 local run = not self.state
		 self.state = true
		 return run and {v}
	      end
	      self.state = false
   end, false},
   DRIVE = {events.TICK, function(ran)
	       local v = player:getControlledVehicle()
	       if v then
		  local run = not self.state
		  self.state = true
		  return run and {v}
	       end
	       self.state = false
   end, false},
   -- Mount is ran either when riding or driving
   MOUNT = {events.TICK, function(ran)
	       local v = player:getVehicle()
	       local d = player:getControlledVehicle()
	       if v then
		  local run = not self.state
		  self.state = true
		  return run and {v,v==d}
	       end
	       self.state = false
   end, false},
   RIDING = {events.TICK, function(self)
		local ride = player:getVehicle()
		if not ride then
		   if self.time > 0 then
		      self.time = 0
		      triggers.DISMOUNT(self.vehicle,self.time)
		   end
		   return
		end
		local drive = player:getControlledVehicle()
		local t = self.time
		if t == 0 then
		   if drive then
		      triggers.DRIVE(drive)
		   else
		      triggers.RIDE(ride)
		   end
		   triggers.MOUNT(ride,drive==ride)
		end
		self.vehicle = drive or ride
		self.time = self.time+1
		return {self.vehicle,t,self.vehicle==drive}
   end, {time=0}, needs = {"MOUNT","DISMOUNT","RIDE","DRIVE"}},
}

if hostp then
   standardTriggers.AVATAR_RENDER[2] = function(self,d,ctx,mat)
      --if ctx == 'FIRST_PERSON' or ctx == 'RENDER' then
      if d ~= self.lastdelta then
	 --return {d,ctx,mat}
	 return self:run(d,ctx,mat)
      end
      return
   end
   standardTriggers.AVATAR_RENDER[3] = function(self,d)
      self.lastdelta = d
   end
   standardTriggers.AVATAR_RENDER[3]={lastdelta=-1,isDirect=true}
else
   -- It is fine to assume non-host should only render this in RENDER context because this is 1 instruction cheaper
   standardTriggers.AVATAR_RENDER[2] = function(self,d,ctx,mat)
      if ctx ~= 'RENDER' then return end
      return {d,false,mat}
   end
   standardTriggers.AVATAR_RENDER[3]={lastdelta=0}
end
   
-- Create render and post_render triggers for every individual context. Also IN_WORLD is named such that it does not semantically conflict with WORLD_RENDER. Not yet sure how they interract or if events.RENDER actually runs in that context. TODO: Cut out shader render and find a way to get the client to tell Figura what mod (and shader) is running it
for name,mode in pairs({FIRST_PERSON='FIRST_PERSON',THIRD_PERSON='RENDER',FIGURA='FIGURA_GUI',UI='MINECRAFT_GUI',PAPERDOLL='PAPERDOLL',WORLD_FIRST_PERSON='FIRST_PERSON_WORLD',IN_WORLD='WORLD',SHADER='OTHER'}) do
   local r = name..'_RENDER'
   local p = name..'_POST_RENDER'
   local t = function(self,d,ctx,mat)
      if ctx ~= mode then return end
      return self:run(d,mat)
      --return {d,mat}
   end
   local f = function(self,d,ctx,mat)
      if ctx == mode then return end
      return self:run(d,ctx,mat)
      --return {d,ctx,mat}
   end
   standardTriggers[r]={events.RENDER,t,{isDirect=true}}
   standardTriggers['NON_'..r]={events.RENDER,f,{isDirect=true}}
   standardTriggers[p]={events.POST_RENDER,t,{isDirect=true}}
   standardTriggers['NON_'..p]={events.POST_RENDER,t,{isDirect=true}}
end
   

local st = {}
for k,v in pairs(standardTriggers) do
   st[k]=v
end
for name,trig in pairs(st) do
   local h = {table.unpack(trig)}
   local u = {table.unpack(trig)}
   local hu = {table.unpack(trig)}
   h.cond = hostp
   hu.cond = hostp
   if trig.needs then
      h.needs = {}
      u.needs = {}
      hu.needs= {}
      for _,dep in ipairs(trig.needs) do
	 table.insert(h.needs,'HOST_'..dep)
	 table.insert(u.needs,dep..'_UNPAUSED')
	 table.insert(hu.needs,"HOST_"..dep..'_UNPAUSED')
      end
   end
   local pred = trig[2]
   local isDirect
   if type(trig[3])=='function' then
      if type(trig[4])=='table' then
	 isDirect = trig[4].isDirect
      else
	 u[4] = {state=u[4]}
	 hu[4] = {state=hu[4]}
      end
   elseif type(trig[3])=='table' then
      isDirect = trig[3].isDirect
   else
      u[3]={state=u[3]}
      hu[3]={state=hu[3]}
   end
   local unpausedp
   if pred and isDirect then
      unpausedp = function(self,...)
	 if client:isPaused() then return end
	 return pred(self,...)
      end
   elseif pred then
      unpausedp = function(self,...)
	 if client:isPaused() then return end
	 local p = pred(self,...)
	 if p then
	    return p
	 end
      end
   else
      unpausedp = function(self,...)
	 if client:isPaused() then return end
	 return {...}
      end
   end
   u[2]=unpausedp
   hu[2]=unpausedp
   standardTriggers['HOST_'..name]=h
   standardTriggers[name..'_UNPAUSED']=u
   standardTriggers['HOST_'..name..'_UNPAUSED']=hu
end
-- unpausedp function used by the wrapped event triggers
--@param self any
--@return any?
local function unpausedp(self,...)
   if client:isPaused() then return end
   return self:run(...)
end

-- For some reason just using events:getEvents() only gets through a couple of them so I guess we have to copy it
local ev = {'ENTITY_INIT','TICK','WORLD_TICK',"RENDER","POST_RENDER",'POST_WORLD_RENDER','ITEM_RENDER','SKULL_RENDER','DAMAGE','USE_ITEM','ARROW_RENDER','TRIDENT_RENDER','ON_PLAY_SOUND','RESOURCE_RELOAD','TOTEM'}
local sillyev = {GUI_RENDER=true,PING_FAILED=true,ERROR=true,SILLY_SOUND_EVENT=true}
for name in pairs(sillyev) do
   table.insert(ev,name)
end
for _,name in ipairs(ev) do
   local event = events[name]
   local needsilly = sillyev[name]
   standardTriggers['HOST_'..name]={event,cond=hostp,silly=needsilly}
   standardTriggers[name..'_UNPAUSED']={event,unpausedp,{isDirect=true},silly=needsilly}
   standardTriggers['HOST_'..name..'_UNPAUSED']={event,unpausedp,{isDirect=true},cond=hostp,silly=needsilly}
end

-- Return if we have the given standard trigger availible
--@param name string
--@return boolean
function m.haveStandardTrigger(name)
   return standardTriggers[name] ~= nil
end

-- Return the data of a standard trigger such that it can be used for other things. Note that this returns it in a different scheme than the data is actually presented in standardTriggers in case the layout is ever changed
--@param name string
--@return trigger?: If the return value is nil, the trigger does not exist
function m.getStandardTrigger(name)
   local trig = standardTriggers[name]
   if trig then
      return {event=trig[1],
	      fn = trig[2],
	      initState = trig[3],
	      needs = trig.needs}
   end
   return nil
end

-- Get the list of availible standard triggers
--@return table
function m.getStandardTriggers()
   return standardTriggers
end

-- Add a standard trigger
--@param name string Standard Trigger name
--@return Trigger, boolean The boolean value is false if the trigger was already registered. The function will error if no standard trigger exists with that name
function m.addStandardTrigger(name)
   local std = standardTriggers[name]
   if std == nil then
      error("No standard trigger is defined with the name "..name)
   end
   local deps = std.needs
   if deps then -- registering trigger dependencies must be done before checking if the trigger doesn't exist for some reason.
      --TODO: Change the fact that the trigger must have all dependencies of dependencies listed too
      for _,dep in ipairs(deps) do
	 local stddep = standardTriggers[dep]
	 if stddep == nil then
	    return error("Standard trigger "..name..' needs undefined standard trigger '..dep..'. This is a bug!')
	 end
	 if triggersAPI[dep] == nil then
	    m.new(dep,nil,select(2,table.unpack(stddep)))
	 end
      end
   end
   if triggersAPI[name] == nil then
      if std.silly and not silly then
	 return error("The "..name..' standard trigger requires sillyplugin.')
      end
      local event = std[1]
      if std.cond ~= nil then
	 return m.new(name,std.cond and std[1],select(2,table.unpack(std))),true
      end
      return m.new(name,table.unpack(std)),true
   end
   return triggersAPI[name],false
end

-- Internal function for registering a new function on a trigger in a way consistant with the semantics of setting an event to a function. It is definitively less performant than trigger:register though and does not offer the flexibility of setting the function's name.
--@param self TriggersAPI
--@param key string
--@param val function
--@return self
local function newTrigger(self,key,val)
   -- It is an error for the key here not to be a string. Furthermore it must be uppercased to be consistant with the event API
   key = string.upper(key)
   local this = triggersAPI[key]
   if this == nil then
      error("No trigger named "..key..' registered')
   elseif type(val) ~= 'function' then
      error("Can't register a non-function for trigger "..key)
   end
   return trigger.register(this,val)
end

setmetatable(triggersAPI,{__newindex = newTrigger})
_m.__newindex = newTrigger

setmetatable(m,_m)

figuraMetatables.TriggersAPI = _m
figuraMetatables.TriggerAPI = trigger

return m
