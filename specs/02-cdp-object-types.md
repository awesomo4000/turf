<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2025-2026 awesomo4000 -->

# How CDP Handles Object References and Type Conversions

## CDP's Object Reference System

CDP uses **Remote Object IDs** to reference JavaScript objects across the protocol boundary.

### Object ID Structure

When CDP returns an object, it provides:

```json
{
  "result": {
    "type": "object",
    "subtype": "array",  // Optional: array, null, node, regexp, date, etc.
    "className": "Array",
    "description": "Array(3)",
    "objectId": "{\"injectedScriptId\":1,\"id\":1}",
    "preview": {  // Optional preview of object properties
      "type": "object",
      "subtype": "array",
      "description": "Array(3)",
      "properties": [...]
    }
  }
}
```

The `objectId` is a JSON-serialized string that uniquely identifies the object in the JavaScript context.

### How CDP Tracks Objects

1. **Injection**: CDP injects a script into each execution context
2. **Object Table**: The injected script maintains an object table
3. **Reference Counting**: Objects are kept alive while CDP holds references
4. **Weak References**: Uses weak maps to avoid preventing GC

Simplified version of what Chrome does internally:

```javascript
// This is conceptually what CDP's injected script does
window.__cdpInjectedScript = {
    _objectGroups: new Map(),
    _idToObject: new Map(),
    _objectToId: new WeakMap(),
    _nextObjectId: 1,
    
    _objectId(object) {
        // Create unique ID for this context
        return JSON.stringify({
            injectedScriptId: this._contextId,
            id: this._nextObjectId++
        });
    },
    
    bind(object, groupName) {
        // Check if already bound
        if (this._objectToId.has(object)) {
            return this._objectToId.get(object);
        }
        
        const id = this._objectId(object);
        const parsedId = JSON.parse(id);
        
        // Store object
        this._idToObject.set(parsedId.id, object);
        this._objectToId.set(object, id);
        
        // Add to group (for bulk release)
        if (!this._objectGroups.has(groupName)) {
            this._objectGroups.set(groupName, new Set());
        }
        this._objectGroups.get(groupName).add(parsedId.id);
        
        return id;
    },
    
    objectForId(objectId) {
        const parsed = JSON.parse(objectId);
        return this._idToObject.get(parsed.id);
    },
    
    releaseObject(objectId) {
        const parsed = JSON.parse(objectId);
        this._idToObject.delete(parsed.id);
    },
    
    releaseObjectGroup(groupName) {
        const group = this._objectGroups.get(groupName);
        if (group) {
            for (const id of group) {
                this._idToObject.delete(id);
            }
            this._objectGroups.delete(groupName);
        }
    }
};
```

## CDP Type System

### Primitive Types

CDP directly returns primitive values:

```json
// Number
{"type": "number", "value": 42, "description": "42"}

// String  
{"type": "string", "value": "hello"}

// Boolean
{"type": "boolean", "value": true}

// Undefined
{"type": "undefined"}

// Symbol
{"type": "symbol", "description": "Symbol(foo)"}

// BigInt
{"type": "bigint", "unserializableValue": "123n"}
```

### Object Types

Objects get an `objectId` and optional `subtype`:

```json
// Regular object
{"type": "object", "className": "Object", "objectId": "..."}

// Array
{"type": "object", "subtype": "array", "className": "Array", "objectId": "..."}

// Null (special case)
{"type": "object", "subtype": "null", "value": null}

// DOM Node
{"type": "object", "subtype": "node", "className": "HTMLDivElement", "objectId": "..."}

// Function
{"type": "function", "className": "Function", "objectId": "...", "description": "function() { ... }"}

// Date
{"type": "object", "subtype": "date", "className": "Date", "objectId": "...", "description": "2024-01-15T..."}

// RegExp
{"type": "object", "subtype": "regexp", "className": "RegExp", "objectId": "...", "description": "/pattern/flags"}

// Promise
{"type": "object", "subtype": "promise", "className": "Promise", "objectId": "..."}

// Error
{"type": "object", "subtype": "error", "className": "Error", "objectId": "...", "description": "Error: message"}
```

### Special Values

Some values can't be serialized to JSON:

```json
// NaN
{"type": "number", "unserializableValue": "NaN"}

// Infinity
{"type": "number", "unserializableValue": "Infinity"}

// -Infinity
{"type": "number", "unserializableValue": "-Infinity"}

// -0
{"type": "number", "unserializableValue": "-0"}

// BigInt
{"type": "bigint", "unserializableValue": "9007199254740993n"}
```

## Using Object References

### Getting an Object

```json
// Request
{
  "method": "Runtime.evaluate",
  "params": {
    "expression": "document.querySelector('button')",
    "objectGroup": "myGroup"  // Optional: group for bulk release
  }
}

// Response with objectId
{
  "result": {
    "result": {
      "type": "object",
      "subtype": "node",
      "className": "HTMLButtonElement",
      "objectId": "{\"injectedScriptId\":1,\"id\":123}"
    }
  }
}
```

### Calling Methods on Objects

```json
// Using the objectId from above
{
  "method": "Runtime.callFunctionOn",
  "params": {
    "objectId": "{\"injectedScriptId\":1,\"id\":123}",
    "functionDeclaration": "function() { this.click(); return this.textContent; }",
    "returnByValue": true  // Return primitive value, not object reference
  }
}
```

### Getting Object Properties

```json
{
  "method": "Runtime.getProperties",
  "params": {
    "objectId": "{\"injectedScriptId\":1,\"id\":123}",
    "ownProperties": true,
    "accessorPropertiesOnly": false
  }
}

// Returns
{
  "result": [
    {
      "name": "textContent",
      "value": {
        "type": "string",
        "value": "Click me"
      }
    },
    {
      "name": "onclick",
      "value": {
        "type": "function",
        "objectId": "..."
      }
    }
  ]
}
```

### Releasing Objects

```json
// Release single object
{
  "method": "Runtime.releaseObject",
  "params": {
    "objectId": "{\"injectedScriptId\":1,\"id\":123}"
  }
}

// Release entire group
{
  "method": "Runtime.releaseObjectGroup",
  "params": {
    "objectGroup": "myGroup"
  }
}
```

## Type Conversion Strategies

### For Turf Implementation

```zig
const CDPValue = union(enum) {
    // Primitives
    number: f64,
    string: []const u8,
    boolean: bool,
    undefined: void,
    null: void,
    
    // Objects (need object ID)
    object: struct {
        className: []const u8,
        objectId: []const u8,
        subtype: ?[]const u8,
    },
    
    // Special
    unserializable: []const u8,  // NaN, Infinity, BigInt
    
    pub fn fromJSON(json: std.json.Value) CDPValue {
        const type_str = json.Object.get("type").?.String;
        
        if (std.mem.eql(u8, type_str, "number")) {
            if (json.Object.get("unserializableValue")) |v| {
                return .{ .unserializable = v.String };
            }
            return .{ .number = json.Object.get("value").?.Float };
        } else if (std.mem.eql(u8, type_str, "string")) {
            return .{ .string = json.Object.get("value").?.String };
        } else if (std.mem.eql(u8, type_str, "boolean")) {
            return .{ .boolean = json.Object.get("value").?.Bool };
        } else if (std.mem.eql(u8, type_str, "undefined")) {
            return .undefined;
        } else if (std.mem.eql(u8, type_str, "object")) {
            const subtype = if (json.Object.get("subtype")) |v| v.String else null;
            
            // Check for null
            if (subtype != null and std.mem.eql(u8, subtype.?, "null")) {
                return .null;
            }
            
            return .{ .object = .{
                .className = json.Object.get("className").?.String,
                .objectId = json.Object.get("objectId").?.String,
                .subtype = subtype,
            }};
        }
        
        return .undefined;
    }
};
```

### JavaScript Type Detection

```javascript
// Helper to get CDP type info
function getCDPType(value) {
    if (value === null) {
        return { type: 'object', subtype: 'null', value: null };
    }
    
    const type = typeof value;
    
    if (type === 'number') {
        if (isNaN(value)) {
            return { type: 'number', unserializableValue: 'NaN' };
        }
        if (!isFinite(value)) {
            return { type: 'number', unserializableValue: value > 0 ? 'Infinity' : '-Infinity' };
        }
        if (Object.is(value, -0)) {
            return { type: 'number', unserializableValue: '-0' };
        }
        return { type: 'number', value: value };
    }
    
    if (type === 'bigint') {
        return { type: 'bigint', unserializableValue: value.toString() + 'n' };
    }
    
    if (type === 'object') {
        // Determine subtype
        let subtype = null;
        if (Array.isArray(value)) subtype = 'array';
        else if (value instanceof Date) subtype = 'date';
        else if (value instanceof RegExp) subtype = 'regexp';
        else if (value instanceof Error) subtype = 'error';
        else if (value instanceof Promise) subtype = 'promise';
        else if (value instanceof Node) subtype = 'node';
        
        // Would need object registration here
        return {
            type: 'object',
            subtype: subtype,
            className: value.constructor.name,
            objectId: registerObject(value)
        };
    }
    
    // Primitives
    return { type: type, value: value };
}
```

## Key Differences from Simple Retain/Release

1. **Object Groups**: CDP allows grouping objects for bulk release
2. **Execution Context**: Object IDs are scoped to execution contexts
3. **Type Metadata**: Rich type information including className and subtype
4. **Preview Data**: Optional preview of object properties without fetching
5. **Weak References**: CDP uses weak maps internally to allow GC
6. **Automatic Cleanup**: Objects released when execution context destroyed

## For Turf Implementation

Turf should implement a simplified version:
1. Use the retain/release pattern from spec 01
2. Add type detection for proper conversions
3. Include className for debugging
4. Skip the complexity of object groups unless needed
5. Use strong references while retained (simpler than CDP's weak maps)

The key insight: CDP's object reference system is just a more complex version of the retain/release pattern, with additional metadata for debugging and type information.
