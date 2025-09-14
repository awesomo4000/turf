# Object Retain/Release Registry for Native-JS Communication

## Problem

When native code (Zig) receives a JavaScript object in a response, it needs to:
1. Reference that object later for method calls or property access
2. Prevent the object from being garbage collected while native code holds a reference
3. Allow garbage collection when native code is done with the object

JavaScript has no built-in way to create persistent handles for objects that native code can use.

## Solution: Reference-Counted Object Registry

Implement a registry with explicit retain/release semantics, similar to how Electron, Tauri, and other native/JS frameworks handle object lifetime.

## JavaScript Implementation

```javascript
// Injected into webview on initialization
window.__nativeRefs = {
    objects: new Map(),      // id -> WeakRef(object)
    refCounts: new Map(),    // id -> number
    strongRefs: new Map(),   // id -> object (while retained)
    nextId: 1,
    
    // Native calls this to store an object and get an ID
    retain(obj) {
        // Check if already tracked
        for (let [id, weakRef] of this.objects) {
            const existing = weakRef.deref();
            if (existing === obj) {
                // Increment ref count for existing object
                this.refCounts.set(id, (this.refCounts.get(id) || 0) + 1);
                return id;
            }
        }
        
        // New object - create ID and store
        const id = this.nextId++;
        this.objects.set(id, new WeakRef(obj));
        this.refCounts.set(id, 1);
        
        // Keep strong reference while retained
        this.strongRefs.set(id, obj);
        
        return id;
    },
    
    // Native calls this when done with object
    release(id) {
        const count = this.refCounts.get(id) || 0;
        if (count > 1) {
            // Still referenced, just decrement
            this.refCounts.set(id, count - 1);
        } else {
            // No more references - allow GC
            this.refCounts.delete(id);
            this.objects.delete(id);
            this.strongRefs.delete(id);  // Remove strong ref, allow GC
        }
    },
    
    // Get object by ID
    get(id) {
        const ref = this.objects.get(id);
        if (ref) {
            const obj = ref.deref();
            if (obj) return obj;
            
            // Object was GC'd despite our best efforts
            // (shouldn't happen with proper retain/release)
            console.error(`Object ${id} was garbage collected while retained!`);
            this.cleanup(id);
        }
        return null;
    },
    
    // Call method on retained object
    callMethod(id, method, ...args) {
        const obj = this.get(id);
        if (!obj) throw new Error(`Object ${id} no longer exists`);
        
        const fn = obj[method];
        if (typeof fn !== 'function') {
            throw new Error(`${method} is not a function on object ${id}`);
        }
        
        return fn.apply(obj, args);
    },
    
    // Get property from retained object
    getProperty(id, property) {
        const obj = this.get(id);
        if (!obj) throw new Error(`Object ${id} no longer exists`);
        return obj[property];
    },
    
    // Set property on retained object
    setProperty(id, property, value) {
        const obj = this.get(id);
        if (!obj) throw new Error(`Object ${id} no longer exists`);
        obj[property] = value;
    },
    
    // Internal cleanup
    cleanup(id) {
        this.objects.delete(id);
        this.refCounts.delete(id);
        this.strongRefs.delete(id);
    },
    
    // Debug: Show current references
    debug() {
        console.log('Retained objects:', {
            count: this.strongRefs.size,
            ids: Array.from(this.refCounts.keys()),
            refCounts: Object.fromEntries(this.refCounts)
        });
    }
};
```

## Native Side (Zig)

```zig
const std = @import("std");

pub const JSObjectRef = struct {
    id: u32,
    window: *Window,
    
    /// Create a reference to a JavaScript object
    pub fn init(window: *Window, js_code: []const u8) !JSObjectRef {
        // Execute JS and retain the result
        const id_str = try window.call(
            \\(() => {
            \\    const obj = {s};
            \\    if (obj === null || obj === undefined) return 0;
            \\    return window.__nativeRefs.retain(obj);
            \\})()
        , .{js_code});
        
        const id = try std.fmt.parseInt(u32, id_str, 10);
        if (id == 0) return error.NullObject;
        
        return JSObjectRef{
            .id = id,
            .window = window,
        };
    }
    
    /// Create from an existing object ID (already retained)
    pub fn fromId(window: *Window, id: u32) JSObjectRef {
        return JSObjectRef{
            .id = id,
            .window = window,
        };
    }
    
    /// Release the JavaScript object reference
    pub fn deinit(self: *JSObjectRef) void {
        self.window.call(
            "window.__nativeRefs.release({d})",
            .{self.id}
        ) catch |err| {
            std.log.warn("Failed to release JS object {d}: {}", .{self.id, err});
        };
    }
    
    /// Call a method on the object
    pub fn callMethod(self: JSObjectRef, method: []const u8, args: []const u8) ![]const u8 {
        return self.window.call(
            "window.__nativeRefs.callMethod({d}, '{s}', {s})",
            .{self.id, method, args}
        );
    }
    
    /// Get a property value
    pub fn getProperty(self: JSObjectRef, property: []const u8) ![]const u8 {
        return self.window.call(
            "window.__nativeRefs.getProperty({d}, '{s}')",
            .{self.id, property}
        );
    }
    
    /// Set a property value  
    pub fn setProperty(self: JSObjectRef, property: []const u8, value: []const u8) !void {
        _ = try self.window.call(
            "window.__nativeRefs.setProperty({d}, '{s}', {s})",
            .{self.id, property, value}
        );
    }
    
    /// Check if object still exists
    pub fn isValid(self: JSObjectRef) bool {
        const result = self.window.call(
            "window.__nativeRefs.get({d}) !== null",
            .{self.id}
        ) catch {
            return false;
        };
        return std.mem.eql(u8, result, "true");
    }
};

/// Manages multiple object references with automatic cleanup
pub const JSObjectScope = struct {
    refs: std.ArrayList(JSObjectRef),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) JSObjectScope {
        return .{
            .refs = std.ArrayList(JSObjectRef).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *JSObjectScope) void {
        // Release all objects in scope
        for (self.refs.items) |*ref| {
            ref.deinit();
        }
        self.refs.deinit();
    }
    
    pub fn add(self: *JSObjectScope, ref: JSObjectRef) !void {
        try self.refs.append(ref);
    }
};
```

## Usage Examples

### Basic Object Retention

```zig
// Get a DOM element and keep it alive
const button = try JSObjectRef.init(&window, "document.querySelector('button')");
defer button.deinit();  // Automatically release when done

// Use the object multiple times
try button.callMethod("click", "");
const text = try button.getProperty("textContent");
try button.setProperty("disabled", "true");
```

### Working with Multiple Objects

```zig
var scope = JSObjectScope.init(allocator);
defer scope.deinit();  // Releases all objects

// Get multiple elements
const form = try JSObjectRef.init(&window, "document.querySelector('form')");
try scope.add(form);

const inputs = try JSObjectRef.init(&window, "document.querySelectorAll('input')");
try scope.add(inputs);

// Work with them...
const length = try inputs.getProperty("length");
```

### Handling Async Operations

```javascript
// JavaScript side - retaining promise results
window.__nativeRefs.retainPromise = async function(promiseCode) {
    try {
        const result = await eval(promiseCode);
        
        // If result is an object, retain it
        if (result && typeof result === 'object') {
            return this.retain(result);
        }
        
        // Primitive value, return directly
        return result;
    } catch (error) {
        console.error('Promise failed:', error);
        return null;
    }
};
```

```zig
// Native side - get object from async operation
const response_id = try window.call(
    "window.__nativeRefs.retainPromise('fetch(\"/api/data\").then(r => r.json())')"
);

if (response_id != 0) {
    const response = JSObjectRef.fromId(&window, response_id);
    defer response.deinit();
    
    const data = try response.getProperty("data");
    // Use data...
}
```

## Memory Management Best Practices

1. **Always Release**: Use `defer` in Zig to ensure objects are released
2. **Scope Management**: Use `JSObjectScope` for multiple related objects
3. **Error Handling**: Release objects even on error paths
4. **Validate References**: Check `isValid()` for long-lived references
5. **Debug Leaks**: Call `window.__nativeRefs.debug()` to see retained objects

## Comparison with Other Frameworks

| Framework | Approach | Notes |
|-----------|----------|-------|
| Electron | Remote objects with ref counting | Similar to our approach |
| Tauri | Commands with state management | Per-window cleanup |
| React Native | Bridge with native modules | Module-based ref counting |
| Flutter | Platform channels | No direct object refs |
| Node.js N-API | Handle scopes | Automatic scope-based cleanup |

## Implementation Checklist

- [ ] Inject `__nativeRefs` registry on window initialization
- [ ] Implement `JSObjectRef` struct in Zig
- [ ] Add `JSObjectScope` for multiple objects
- [ ] Handle promise results that return objects
- [ ] Add debug/diagnostic commands
- [ ] Test with DOM elements
- [ ] Test with JavaScript objects
- [ ] Test with arrays and collections
- [ ] Verify no memory leaks
- [ ] Add cleanup on window close

## Conclusion

This retain/release pattern with reference counting provides a robust way to manage JavaScript object lifetime from native code. The strong references prevent premature garbage collection while the reference counting ensures proper cleanup when native code is done with objects.