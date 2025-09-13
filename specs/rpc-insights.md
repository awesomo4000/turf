# RPC Insights for Turf

## Key Insights for Bidirectional Calls

### Call IDs Are Essential
Yes, you need call IDs to correlate requests with responses. This is how every RPC system works (including CDP).

### JavaScript Execution Model
- JavaScript is **single-threaded** but **asynchronous**
- `evalJavaScript` likely returns immediately (fire-and-forget)
- Results must come back via message handlers
- Can't just "wait" - need proper async handling

### Promise Handling
When JavaScript returns a Promise:
1. **Detect it**: `typeof result.then === 'function'`
2. **Store it**: Keep promise reference with call ID
3. **Wait for it**: Use `await` or `.then()` in JavaScript
4. **Send result**: When promise resolves, send result with call ID
5. **Match on native**: Native side matches response to pending call

## The Architecture

```
Native (Zig)              JavaScript
    |                         |
    |--[call_id:1]----------->|
    |  "fetch('/api')"        | 
    |                         | eval(code)
    |                         | returns Promise
    |<--[call_pending:1]------|
    |  "async operation"      |
    |                         | ... promise resolves
    |<--[call_response:1]-----|
    |  {data: ...}            |
    |                         |
```

## Implementation Pattern

The pattern is:
1. Wrap JS code to capture result
2. Check if result is a promise
3. If sync: send result immediately  
4. If async: send "pending" then wait and send result
5. Native side either blocks or returns a promise

This turns Turf's one-way message passing into a full RPC system with promise support!