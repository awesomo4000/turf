# JavaScript ↔ Zig Type Conversions

## Overview

This spec defines how to convert between JavaScript and Zig types when passing data through Turf's message system.

## Type Mapping Table

| JavaScript Type | Zig Type | JSON Representation | Notes |
|----------------|----------|-------------------|--------|
| `number` | `f64` | `{"type": "number", "value": 42}` | All JS numbers are f64 |
| `string` | `[]const u8` | `{"type": "string", "value": "hello"}` | UTF-8 encoded |
| `boolean` | `bool` | `{"type": "boolean", "value": true}` | |
| `null` | `?T` or enum tag | `{"type": "null"}` | Zig optionals or tagged union |
| `undefined` | `void` or enum tag | `{"type": "undefined"}` | |
| `bigint` | `i128` or `[]const u8` | `{"type": "bigint", "value": "123n"}` | String representation |
| `object` | `u32` (handle) | `{"type": "object", "id": 123}` | Object reference ID |
| `array` | `[]T` or handle | `{"type": "array", "values": [...]}` | Can serialize or use handle |
| `function` | `u32` (handle) | `{"type": "function", "id": 456}` | Function reference ID |
| `symbol` | Not supported | `{"type": "symbol", "description": "Symbol(foo)"}` | Description only |
| `Date` | `i64` (timestamp) | `{"type": "date", "value": 1705334400000}` | Milliseconds since epoch |
| `RegExp` | `struct { pattern, flags }` | `{"type": "regexp", "pattern": "\\d+", "flags": "gi"}` | |
| `Error` | `struct { message, stack }` | `{"type": "error", "message": "...", "stack": "..."}` | |
| `ArrayBuffer` | `[]u8` | `{"type": "buffer", "data": "base64..."}` | Base64 encoded |
| `Promise` | Handle + callback | `{"type": "promise", "id": 789}` | Special async handling |

## JavaScript → Zig Conversion

### Detection and Serialization (JavaScript)

```javascript
window.__turfTypes = {
    // Serialize any JavaScript value for Zig
    serialize(value) {
        // Handle null specially (typeof null === 'object')
        if (value === null) {
            return { type: 'null' };
        }
        
        // Handle undefined
        if (value === undefined) {
            return { type: 'undefined' };
        }
        
        const type = typeof value;
        
        // Primitives
        if (type === 'number') {
            // Check for special values
            if (isNaN(value)) {
                return { type: 'number', special: 'NaN' };
            }
            if (!isFinite(value)) {
                return { type: 'number', special: value > 0 ? 'Infinity' : '-Infinity' };
            }
            if (Object.is(value, -0)) {
                return { type: 'number', special: '-0' };
            }
            return { type: 'number', value: value };
        }
        
        if (type === 'string') {
            return { type: 'string', value: value };
        }
        
        if (type === 'boolean') {
            return { type: 'boolean', value: value };
        }
        
        if (type === 'bigint') {
            return { type: 'bigint', value: value.toString() };
        }
        
        if (type === 'symbol') {
            return { type: 'symbol', description: value.toString() };
        }
        
        if (type === 'function') {
            // Store function and return handle
            const id = window.__nativeRefs.retain(value);
            return { 
                type: 'function', 
                id: id,
                name: value.name || 'anonymous',
                length: value.length  // number of parameters
            };
        }
        
        // Objects - need more classification
        if (type === 'object') {
            // Arrays - can serialize small ones
            if (Array.isArray(value)) {
                if (value.length <= 100) {
                    // Small array - serialize directly
                    return {
                        type: 'array',
                        values: value.map(v => this.serialize(v))
                    };
                } else {
                    // Large array - use handle
                    const id = window.__nativeRefs.retain(value);
                    return { type: 'array', id: id, length: value.length };
                }
            }
            
            // Date
            if (value instanceof Date) {
                return { 
                    type: 'date', 
                    value: value.getTime(),  // milliseconds since epoch
                    iso: value.toISOString()  // for debugging
                };
            }
            
            // RegExp
            if (value instanceof RegExp) {
                return {
                    type: 'regexp',
                    pattern: value.source,
                    flags: value.flags
                };
            }
            
            // Error
            if (value instanceof Error) {
                return {
                    type: 'error',
                    name: value.name,
                    message: value.message,
                    stack: value.stack
                };
            }
            
            // ArrayBuffer / TypedArray
            if (value instanceof ArrayBuffer) {
                const bytes = new Uint8Array(value);
                const b64 = btoa(String.fromCharCode(...bytes));
                return { type: 'buffer', data: b64 };
            }
            
            if (ArrayBuffer.isView(value)) {
                const bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
                const b64 = btoa(String.fromCharCode(...bytes));
                return { 
                    type: 'typedarray',
                    arrayType: value.constructor.name,
                    data: b64 
                };
            }
            
            // Promise - special handling
            if (value instanceof Promise) {
                const id = window.__nativeRefs.retain(value);
                // Mark as pending, will resolve later
                value.then(
                    result => this.resolvePromise(id, result),
                    error => this.rejectPromise(id, error)
                );
                return { type: 'promise', id: id, status: 'pending' };
            }
            
            // DOM nodes
            if (value instanceof Node) {
                const id = window.__nativeRefs.retain(value);
                return {
                    type: 'domnode',
                    id: id,
                    nodeName: value.nodeName,
                    nodeType: value.nodeType
                };
            }
            
            // Generic object - use handle
            const id = window.__nativeRefs.retain(value);
            return {
                type: 'object',
                id: id,
                className: value.constructor.name,
                // Optional: include some properties for debugging
                preview: this.getObjectPreview(value)
            };
        }
        
        // Fallback
        return { type: 'unknown', string: String(value) };
    },
    
    // Get limited preview of object properties
    getObjectPreview(obj, maxProps = 5) {
        const preview = {};
        let count = 0;
        for (const key in obj) {
            if (count >= maxProps) break;
            try {
                const value = obj[key];
                const type = typeof value;
                if (type === 'function') {
                    preview[key] = '[Function]';
                } else if (type === 'object' && value !== null) {
                    preview[key] = `[${value.constructor.name}]`;
                } else {
                    preview[key] = value;
                }
                count++;
            } catch (e) {
                preview[key] = '[Error reading property]';
            }
        }
        return preview;
    }
};
```

### Deserialization (Zig)

```zig
const std = @import("std");

pub const JSType = enum {
    number,
    string,
    boolean,
    null,
    undefined,
    bigint,
    symbol,
    object,
    array,
    function,
    date,
    regexp,
    @"error",
    buffer,
    promise,
    domnode,
    unknown,
};

pub const JSValue = union(JSType) {
    number: union(enum) {
        normal: f64,
        special: enum { nan, infinity, negative_infinity, negative_zero },
    },
    string: []const u8,
    boolean: bool,
    null: void,
    undefined: void,
    bigint: []const u8,  // String representation
    symbol: []const u8,  // Description only
    object: ObjectRef,
    array: union(enum) {
        serialized: []JSValue,
        reference: ObjectRef,
    },
    function: FunctionRef,
    date: i64,  // Milliseconds since epoch
    regexp: struct {
        pattern: []const u8,
        flags: []const u8,
    },
    @"error": struct {
        name: []const u8,
        message: []const u8,
        stack: []const u8,
    },
    buffer: []u8,  // Decoded from base64
    promise: PromiseRef,
    domnode: DOMNodeRef,
    unknown: []const u8,
    
    pub fn fromJSON(allocator: std.mem.Allocator, json: std.json.Value) !JSValue {
        const obj = json.Object;
        const type_str = obj.get("type").?.String;
        
        if (std.mem.eql(u8, type_str, "number")) {
            if (obj.get("special")) |special| {
                const special_str = special.String;
                if (std.mem.eql(u8, special_str, "NaN")) {
                    return .{ .number = .{ .special = .nan } };
                } else if (std.mem.eql(u8, special_str, "Infinity")) {
                    return .{ .number = .{ .special = .infinity } };
                } else if (std.mem.eql(u8, special_str, "-Infinity")) {
                    return .{ .number = .{ .special = .negative_infinity } };
                } else if (std.mem.eql(u8, special_str, "-0")) {
                    return .{ .number = .{ .special = .negative_zero } };
                }
            }
            return .{ .number = .{ .normal = obj.get("value").?.Float } };
        }
        
        if (std.mem.eql(u8, type_str, "string")) {
            const str = try allocator.dupe(u8, obj.get("value").?.String);
            return .{ .string = str };
        }
        
        if (std.mem.eql(u8, type_str, "boolean")) {
            return .{ .boolean = obj.get("value").?.Bool };
        }
        
        if (std.mem.eql(u8, type_str, "null")) {
            return .null;
        }
        
        if (std.mem.eql(u8, type_str, "undefined")) {
            return .undefined;
        }
        
        if (std.mem.eql(u8, type_str, "bigint")) {
            const str = try allocator.dupe(u8, obj.get("value").?.String);
            return .{ .bigint = str };
        }
        
        if (std.mem.eql(u8, type_str, "object")) {
            const id = @intCast(u32, obj.get("id").?.Integer);
            const className = try allocator.dupe(u8, obj.get("className").?.String);
            return .{ .object = ObjectRef{ .id = id, .className = className } };
        }
        
        if (std.mem.eql(u8, type_str, "array")) {
            if (obj.get("values")) |values| {
                // Serialized array
                var array = try allocator.alloc(JSValue, values.Array.items.len);
                for (values.Array.items, 0..) |item, i| {
                    array[i] = try JSValue.fromJSON(allocator, item);
                }
                return .{ .array = .{ .serialized = array } };
            } else {
                // Reference to large array
                const id = @intCast(u32, obj.get("id").?.Integer);
                const length = @intCast(usize, obj.get("length").?.Integer);
                return .{ .array = .{ .reference = ObjectRef{ .id = id, .length = length } } };
            }
        }
        
        if (std.mem.eql(u8, type_str, "date")) {
            return .{ .date = obj.get("value").?.Integer };
        }
        
        if (std.mem.eql(u8, type_str, "buffer")) {
            const b64 = obj.get("data").?.String;
            const decoded = try base64.decode(allocator, b64);
            return .{ .buffer = decoded };
        }
        
        // ... handle other types ...
        
        return .{ .unknown = try allocator.dupe(u8, "unknown type") };
    }
};

pub const ObjectRef = struct {
    id: u32,
    className: ?[]const u8 = null,
    length: ?usize = null,  // For arrays
};

pub const FunctionRef = struct {
    id: u32,
    name: []const u8,
    param_count: u32,
};

pub const PromiseRef = struct {
    id: u32,
    status: enum { pending, resolved, rejected },
};

pub const DOMNodeRef = struct {
    id: u32,
    node_name: []const u8,
    node_type: u32,
};
```

## Zig → JavaScript Conversion

### Zig Serialization

```zig
pub fn toJSON(self: JSValue, allocator: std.mem.Allocator) !std.json.Value {
    switch (self) {
        .number => |n| switch (n) {
            .normal => |v| return .{ .Object = .{
                .{ "type", .{ .String = "number" } },
                .{ "value", .{ .Float = v } },
            }},
            .special => |s| return .{ .Object = .{
                .{ "type", .{ .String = "number" } },
                .{ "special", .{ .String = @tagName(s) } },
            }},
        },
        .string => |s| return .{ .Object = .{
            .{ "type", .{ .String = "string" } },
            .{ "value", .{ .String = s } },
        }},
        .boolean => |b| return .{ .Object = .{
            .{ "type", .{ .String = "boolean" } },
            .{ "value", .{ .Bool = b } },
        }},
        .null => return .{ .Object = .{
            .{ "type", .{ .String = "null" } },
        }},
        .undefined => return .{ .Object = .{
            .{ "type", .{ .String = "undefined" } },
        }},
        // ... other types ...
    }
}
```

### JavaScript Deserialization

```javascript
window.__turfTypes.deserialize = function(data) {
    const type = data.type;
    
    switch(type) {
        case 'number':
            if (data.special) {
                switch(data.special) {
                    case 'nan': return NaN;
                    case 'infinity': return Infinity;
                    case 'negative_infinity': return -Infinity;
                    case 'negative_zero': return -0;
                }
            }
            return data.value;
            
        case 'string':
            return data.value;
            
        case 'boolean':
            return data.value;
            
        case 'null':
            return null;
            
        case 'undefined':
            return undefined;
            
        case 'bigint':
            return BigInt(data.value);
            
        case 'object':
            // Retrieve object by ID
            return window.__nativeRefs.get(data.id);
            
        case 'array':
            if (data.values) {
                // Deserialize array elements
                return data.values.map(v => this.deserialize(v));
            } else {
                // Reference to existing array
                return window.__nativeRefs.get(data.id);
            }
            
        case 'date':
            return new Date(data.value);
            
        case 'regexp':
            return new RegExp(data.pattern, data.flags);
            
        case 'error':
            const err = new Error(data.message);
            err.name = data.name;
            err.stack = data.stack;
            return err;
            
        case 'buffer':
            // Decode base64 to ArrayBuffer
            const binary = atob(data.data);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            return bytes.buffer;
            
        default:
            console.warn('Unknown type:', type);
            return undefined;
    }
};
```

## Special Handling

### Promises

Promises require async handling:

```zig
// Zig side
pub fn callJSAsync(window: *Window, code: []const u8) !PromiseRef {
    const result_json = try window.call(code);
    const value = try JSValue.fromJSON(allocator, result_json);
    
    switch (value) {
        .promise => |p| return p,
        else => {
            // Wrap non-promise in resolved promise
            return PromiseRef{
                .id = 0,
                .status = .resolved,
                .value = value,
            };
        }
    }
}

// Wait for promise
pub fn waitPromise(window: *Window, promise: PromiseRef, timeout_ms: u32) !JSValue {
    // Implementation would poll or use callbacks
}
```

### Circular References

```javascript
// Detect and handle circular references
window.__turfTypes.serialize = function(value, seen = new WeakSet()) {
    if (value && typeof value === 'object') {
        if (seen.has(value)) {
            return { type: 'circular', id: window.__nativeRefs.getId(value) };
        }
        seen.add(value);
    }
    // ... rest of serialization
};
```

### Large Data

For large arrays or strings, use streaming or chunking:

```javascript
// Stream large data in chunks
window.__turfTypes.streamLargeArray = function*(array, chunkSize = 1000) {
    for (let i = 0; i < array.length; i += chunkSize) {
        yield array.slice(i, i + chunkSize);
    }
};
```

## Performance Considerations

1. **Prefer Handles for Objects**: Don't serialize large objects, use references
2. **Batch Operations**: Group multiple conversions together
3. **Lazy Evaluation**: Don't convert until needed
4. **Cache Conversions**: Store frequently used conversions
5. **Use TypedArrays**: For binary data, use ArrayBuffers

## Testing

```zig
test "JavaScript type conversions" {
    // Test all primitive types
    try testConversion(.{ .number = .{ .normal = 42 } });
    try testConversion(.{ .string = "hello" });
    try testConversion(.{ .boolean = true });
    try testConversion(.null);
    try testConversion(.undefined);
    
    // Test special numbers
    try testConversion(.{ .number = .{ .special = .nan } });
    try testConversion(.{ .number = .{ .special = .infinity } });
    
    // Test complex types
    const date = JSValue{ .date = 1705334400000 };
    try testConversion(date);
    
    const regexp = JSValue{ .regexp = .{
        .pattern = "\\d+",
        .flags = "gi",
    }};
    try testConversion(regexp);
}
```

## Conclusion

This type conversion system provides:
1. **Complete Coverage**: All JavaScript types can be represented
2. **Efficiency**: Small data serialized, large data uses handles
3. **Safety**: Circular references and special values handled
4. **Debugging**: Type information preserved for diagnostics
5. **Performance**: Optimized for common cases