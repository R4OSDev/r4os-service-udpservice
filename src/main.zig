const r4os = @import("r4os");

const service_name = "UDPSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const service_timeout_ms: u64 = 1000;
const front_handles_max: usize = 8;
const owner_mismatch_result: i32 = -4;
const no_socket_result: i32 = -1;
const bind_in_use_result: i32 = -2;

const FrontHandle = struct {
    used: bool = false,
    handle: u32 = 0,
    backend_handle: u32 = 0,
    owner_id: u32 = 0,
    local_port: u16 = 0,
};

const ServiceState = struct {
    requests: u64 = 0,
    status_requests: u64 = 0,
    action_requests: u64 = 0,
    bind_requests: u64 = 0,
    send_requests: u64 = 0,
    recv_requests: u64 = 0,
    close_requests: u64 = 0,
    bad_ops: u64 = 0,
    bad_requests: u64 = 0,
    backend_errors: u64 = 0,
    owner_mismatches: u64 = 0,
    duplicate_binds: u64 = 0,
    cleanup_runs: u64 = 0,
    cleanup_handles: u64 = 0,
    self_tests: u64 = 0,
    next_handle: u32 = 1,
    handles: [front_handles_max]FrontHandle = .{FrontHandle{}} ** front_handles_max,
    last_result: i32 = no_socket_result,
    last_handle: u32 = 0,
    last_backend_handle: u32 = 0,
    last_port: u16 = 0,
    last_error: [32]u8 = .{0} ** 32,
    last_lifecycle_cause: u32 = r4os.abi.net_service_socket_lifecycle_unknown,
    lifecycle_closed: u64 = 0,
    lifecycle_timeout: u64 = 0,
    lifecycle_local_close: u64 = 0,
    lifecycle_would_block: u64 = 0,
    lifecycle_bad_handle: u64 = 0,
    lifecycle_dropped: u64 = 0,
};

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

const UdpReply = struct {
    result: r4os.abi.NetServiceUdpResult,
    data: []const u8 = "",
};

const FrontLookup = struct {
    ok: bool = false,
    index: usize = 0,
    entry: FrontHandle = .{},
    result: i32 = no_socket_result,
    last_error: []const u8 = "",
};

// Non-zero initializers keep R4X scratch buffers file-backed instead of BSS-only.
var service_payload_buffer: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var backend_response_buffer: [r4os.abi.ipc_max_message_size]u8 = .{0xA5} ** r4os.abi.ipc_max_message_size;
var backend_result_data: [r4os.abi.net_service_udp_read_max]u8 = .{0xA5} ** r4os.abi.net_service_udp_read_max;
var translated_payload: [r4os.abi.net_service_tcp_message_payload_max]u8 = .{0xA5} ** r4os.abi.net_service_tcp_message_payload_max;
var service_reply_payload: [@sizeOf(r4os.abi.NetServiceUdpResult) + r4os.abi.net_service_udp_read_max]u8 = .{0xA5} ** (@sizeOf(r4os.abi.NetServiceUdpResult) + r4os.abi.net_service_udp_read_max);
var service_status_reply: r4os.abi.NetServiceUdpStatus = .{};
var service_result_reply: r4os.abi.NetServiceUdpResult = .{};
var selftest_status_response: [@sizeOf(r4os.abi.NetServiceUdpStatus)]u8 = .{0xA5} ** @sizeOf(r4os.abi.NetServiceUdpStatus);
var selftest_result_response: [@sizeOf(r4os.abi.NetServiceUdpResult) + 32]u8 = .{0xA5} ** (@sizeOf(r4os.abi.NetServiceUdpResult) + 32);

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(app.sys.argsRaw(), selftest_arg)) return runSelfTest(&app);
    if (hasArg(app.sys.argsRaw(), ping_arg)) return runPing(&app);
    return runService(&app);
}

fn runService(app: *const App) i32 {
    if (!app.sys.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < 100 and handle == 0) : (waited += 1) {
        const rc = app.sys.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            app.sys.write("UDPSVC endpoint handle=");
            app.sys.printU64(@intCast(handle));
            app.sys.println("");
            break;
        }
        app.sys.sleepTicks(1);
    }
    if (handle == 0) {
        app.sys.println("UDPSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state = ServiceState{};
    setLastError(&state, "ready");
    var service_loop = r4os.ServiceLoop.init(app.sys, handle, .{});
    while (true) {
        switch (service_loop.wait(null)) {
            .requests => |pending| {
                const rc = service_loop.drain(pending, handleRequest, .{ app, handle, &state });
                if (rc >= 0) continue;
                cleanupService(app, &state, "request");
                _ = app.sys.serviceEndpointUnregister(handle);
                return rc;
            },
            .idle, .deadline => {},
            .stop => break,
            .failure => |raw| {
                cleanupService(app, &state, "endpoint");
                _ = app.sys.serviceEndpointUnregister(handle);
                return raw;
            },
        }
    }

    service_loop.report(service_name);
    cleanupService(app, &state, "service-stop");
    _ = app.sys.serviceEndpointUnregister(handle);
    app.sys.println("UDPSVC stopped cleanly");
    return 0;
}

fn handleRequest(app: *const App, handle: u32, state: *ServiceState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = app.sys.serviceEndpointRecv(handle, &header, service_payload_buffer[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    const payload_len: usize = @intCast(got);
    const request = service_payload_buffer[0..payload_len];
    return switch (header.op) {
        r4os.abi.net_service_op_status => replyTextStatus(app, handle, header.request_id, state, header.client_id),
        r4os.abi.net_service_op_udp_status_result => replyStatusResult(app, handle, header.request_id, state, header.client_id),
        r4os.abi.net_service_op_udp_bind,
        r4os.abi.net_service_op_udp_sendto,
        r4os.abi.net_service_op_udp_recv,
        r4os.abi.net_service_op_udp_close,
        => replyTextOperation(app, handle, header.request_id, state, header.client_id, resultOpForTextOp(header.op), request),
        r4os.abi.net_service_op_udp_bind_result,
        r4os.abi.net_service_op_udp_sendto_result,
        r4os.abi.net_service_op_udp_recv_result,
        r4os.abi.net_service_op_udp_close_result,
        => replyStructuredOperation(app, handle, header.request_id, state, header.client_id, header.op, request),
        else => {
            state.bad_ops +%= 1;
            return app.sys.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
}

fn replyTextStatus(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32) i32 {
    state.status_requests +%= 1;
    service_status_reply = makeStatus(app, state, owner_id);
    var buf: [512]u8 = .{0} ** 512;
    var w = Writer{ .out = buf[0..] };
    writeStatusText(&w, state, &service_status_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, w.slice());
}

fn replyStatusResult(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32) i32 {
    state.status_requests +%= 1;
    service_status_reply = makeStatus(app, state, owner_id);
    const bytes: [*]const u8 = @ptrCast(&service_status_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.NetServiceUdpStatus)]);
}

fn replyTextOperation(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32, op: u16, request: []const u8) i32 {
    if (op == 0) {
        state.bad_ops +%= 1;
        return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_bad_op, "BADOP");
    }
    const reply = performOperation(app, state, owner_id, op, request, backend_result_data[0..]);
    var buf: [512]u8 = .{0} ** 512;
    var w = Writer{ .out = buf[0..] };
    writeOperationText(&w, &reply.result, reply.data);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, w.slice());
}

fn replyStructuredOperation(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32, op: u16, request: []const u8) i32 {
    const reply = performOperation(app, state, owner_id, op, request, backend_result_data[0..]);
    service_result_reply = reply.result;
    const result_bytes: [*]const u8 = @ptrCast(&service_result_reply);
    @memcpy(service_reply_payload[0..@sizeOf(r4os.abi.NetServiceUdpResult)], result_bytes[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    const data_len: usize = if ((service_result_reply.flags & r4os.abi.net_service_udp_flag_data) != 0) @intCast(service_result_reply.bytes) else 0;
    if (data_len != 0) @memcpy(service_reply_payload[@sizeOf(r4os.abi.NetServiceUdpResult) .. @sizeOf(r4os.abi.NetServiceUdpResult) + data_len], reply.data[0..data_len]);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, service_reply_payload[0 .. @sizeOf(r4os.abi.NetServiceUdpResult) + data_len]);
}

fn performOperation(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8) UdpReply {
    state.action_requests +%= 1;
    return switch (op) {
        r4os.abi.net_service_op_udp_bind_result => blk: {
            state.bind_requests +%= 1;
            break :blk performBind(app, state, owner_id, op, request, data_out);
        },
        r4os.abi.net_service_op_udp_sendto_result => blk: {
            state.send_requests +%= 1;
            break :blk performHandleOperation(app, state, owner_id, op, request, data_out, false);
        },
        r4os.abi.net_service_op_udp_recv_result => blk: {
            state.recv_requests +%= 1;
            break :blk performHandleOperation(app, state, owner_id, op, request, data_out, false);
        },
        r4os.abi.net_service_op_udp_close_result => blk: {
            state.close_requests +%= 1;
            break :blk performHandleOperation(app, state, owner_id, op, request, data_out, true);
        },
        else => localError(app, state, op, 0, r4os.abi.net_service_result_bad_op, "bad-op"),
    };
}

fn performBind(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8) UdpReply {
    if (request.len < 2) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    const port = readLe16(request, 0);
    state.last_port = port;
    if (port == 0) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-port");
    if (frontForPort(state, port)) |idx| {
        state.duplicate_binds +%= 1;
        if (!ownerMatches(state.handles[idx].owner_id, owner_id)) return ownerMismatch(state, op, 0, port);
        return localError(app, state, op, 0, bind_in_use_result, "bind-in-use");
    }
    var reply = backendResult(app, op, request, data_out) orelse return backendError(app, state, op, "backend");
    if (reply.result.result == 0 and (reply.result.flags & r4os.abi.net_service_udp_flag_handle_valid) != 0) {
        const backend_handle = reply.result.handle;
        const front = allocateFrontHandle(state, owner_id, backend_handle, port) orelse {
            closeBackendHandle(app, backend_handle);
            return localError(app, state, op, 0, -3, "handle-full");
        };
        reply.result.handle = front;
        reply.result.dest_port = port;
        reply.result.flags |= r4os.abi.net_service_udp_flag_handle_valid;
        state.last_handle = front;
        state.last_backend_handle = backend_handle;
    }
    noteResult(state, &reply.result);
    return reply;
}

fn performHandleOperation(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8, release_on_success: bool) UdpReply {
    if (request.len < 4) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    const front_handle = readLe32(request, 0);
    const lookup = resolveFrontHandle(state, front_handle, owner_id);
    if (!lookup.ok) return localError(app, state, op, front_handle, lookup.result, lookup.last_error);
    const translated = translateHandlePayload(request, lookup.entry.backend_handle) orelse return localError(app, state, op, front_handle, r4os.abi.net_service_result_bad_request, "too-large");
    var reply = backendResult(app, op, translated, data_out) orelse return backendError(app, state, op, "backend");
    reply.result.handle = front_handle;
    reply.result.dest_port = if (reply.result.dest_port != 0) reply.result.dest_port else lookup.entry.local_port;
    reply.result.flags |= r4os.abi.net_service_udp_flag_handle_valid;
    if (release_on_success and (reply.result.result == 0 or reply.result.result == no_socket_result)) releaseFrontHandleAt(state, lookup.index);
    state.last_handle = front_handle;
    state.last_backend_handle = lookup.entry.backend_handle;
    state.last_port = lookup.entry.local_port;
    noteResult(state, &reply.result);
    return reply;
}

fn backendStatus(app: *const App, out: *r4os.abi.NetServiceUdpStatus) bool {
    const got = app.net.netServiceRequest(r4os.abi.ipc_channel_net_udp, r4os.abi.net_service_op_udp_status_result, 0x53564455, "", backend_response_buffer[0..]);
    if (got <= 0) return false;
    var status: i32 = 0;
    const payload = app.net.netServicePayload(backend_response_buffer[0..@as(usize, @intCast(got))], &status) orelse return false;
    if (status != r4os.abi.net_service_result_ok or payload.len < @sizeOf(r4os.abi.NetServiceUdpStatus)) return false;
    copyStruct(out, payload[0..@sizeOf(r4os.abi.NetServiceUdpStatus)]);
    return out.magic == r4os.abi.net_service_udp_status_magic and out.version == r4os.abi.net_service_udp_status_version;
}

fn backendResult(app: *const App, op: u16, request: []const u8, data_out: []u8) ?UdpReply {
    const got = app.net.netServiceRequest(r4os.abi.ipc_channel_net_udp, op, 0x52564455, request, backend_response_buffer[0..]);
    if (got <= 0) return null;
    var status: i32 = 0;
    const payload = app.net.netServicePayload(backend_response_buffer[0..@as(usize, @intCast(got))], &status) orelse return null;
    if (status != r4os.abi.net_service_result_ok or payload.len < @sizeOf(r4os.abi.NetServiceUdpResult)) return null;
    var result = r4os.abi.NetServiceUdpResult{};
    copyStruct(&result, payload[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.magic != r4os.abi.net_service_udp_result_magic or result.version != r4os.abi.net_service_udp_result_version) return null;
    var data_len: usize = 0;
    const available = payload[@sizeOf(r4os.abi.NetServiceUdpResult)..];
    if ((result.flags & r4os.abi.net_service_udp_flag_data) != 0 and result.bytes != 0) {
        data_len = @intCast(result.bytes);
        if (data_len > available.len or data_len > data_out.len) return null;
        copyBytes(data_out[0..data_len], available[0..data_len]);
    }
    return .{ .result = result, .data = data_out[0..data_len] };
}

fn backendError(app: *const App, state: *ServiceState, op: u16, label: []const u8) UdpReply {
    state.backend_errors +%= 1;
    return localError(app, state, op, 0, r4os.abi.net_service_result_bad_service, label);
}

fn localError(app: *const App, state: *ServiceState, op: u16, handle: u32, result_code: i32, reason: []const u8) UdpReply {
    _ = app;
    state.bad_requests +%= 1;
    var out = r4os.abi.NetServiceUdpResult{
        .action = actionForOp(op),
        .result = result_code,
        .flags = withServiceStatus(0, r4os.abi.net_service_status_failed),
        .handle = handle,
        .active_sockets = frontHandleCount(state),
        .max_sockets = front_handles_max,
        .service_status = r4os.abi.net_service_status_failed,
        .message_payload_max = r4os.abi.net_service_tcp_message_payload_max,
        .send_max = r4os.abi.net_service_udp_send_max,
        .recv_max = r4os.abi.net_service_udp_read_max,
    };
    if (handle != 0) out.flags |= r4os.abi.net_service_udp_flag_handle_valid;
    setUdpLifecycle(&out, lifecycleFromReason(reason));
    recordUdpLifecycle(state, out.lifecycle_cause);
    copyFixed(out.last_error[0..], reason);
    noteResult(state, &out);
    return .{ .result = out };
}

fn ownerMismatch(state: *ServiceState, op: u16, handle: u32, port: u16) UdpReply {
    state.owner_mismatches +%= 1;
    var out = r4os.abi.NetServiceUdpResult{
        .action = actionForOp(op),
        .result = owner_mismatch_result,
        .flags = withServiceStatus(0, r4os.abi.net_service_status_failed),
        .handle = handle,
        .dest_port = port,
        .active_sockets = frontHandleCount(state),
        .max_sockets = front_handles_max,
        .lifecycle_cause = r4os.abi.net_service_socket_lifecycle_owner_mismatch,
        .service_status = r4os.abi.net_service_status_failed,
        .message_payload_max = r4os.abi.net_service_tcp_message_payload_max,
        .send_max = r4os.abi.net_service_udp_send_max,
        .recv_max = r4os.abi.net_service_udp_read_max,
    };
    if (handle != 0) out.flags |= r4os.abi.net_service_udp_flag_handle_valid;
    out.flags |= r4os.abi.net_service_udp_flag_lifecycle_valid;
    recordUdpLifecycle(state, out.lifecycle_cause);
    copyFixed(out.last_error[0..], "owner-mismatch");
    noteResult(state, &out);
    return .{ .result = out };
}

fn makeStatus(app: *const App, state: *ServiceState, owner_id: u32) r4os.abi.NetServiceUdpStatus {
    _ = owner_id;
    var out = r4os.abi.NetServiceUdpStatus{};
    if (!backendStatus(app, &out)) {
        out.payload_max = 0;
        copyFixed(out.last_error[0..], "backend");
    }
    out.active_sockets = frontHandleCount(state);
    out.max_sockets = front_handles_max;
    out.message_payload_max = r4os.abi.net_service_tcp_message_payload_max;
    out.send_max = r4os.abi.net_service_udp_send_max;
    out.recv_max = r4os.abi.net_service_udp_read_max;
    out.lifecycle_closed +%= state.lifecycle_closed;
    out.lifecycle_timeout +%= state.lifecycle_timeout;
    out.lifecycle_local_close +%= state.lifecycle_local_close;
    out.lifecycle_would_block +%= state.lifecycle_would_block;
    out.lifecycle_bad_handle +%= state.lifecycle_bad_handle;
    out.lifecycle_dropped +%= state.lifecycle_dropped;
    if (state.last_lifecycle_cause != r4os.abi.net_service_socket_lifecycle_unknown) {
        out.last_lifecycle_cause = state.last_lifecycle_cause;
        out.flags |= r4os.abi.net_service_udp_status_flag_lifecycle_valid;
    }
    if (spanZ(state.last_error[0..]).len != 0) copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
}

fn writeStatusText(w: *Writer, state: *const ServiceState, status: *const r4os.abi.NetServiceUdpStatus) void {
    w.text("sockets=");
    w.num(status.active_sockets);
    w.text("/");
    w.num(status.max_sockets);
    w.text(" queue=");
    w.num(status.queued_packets);
    w.text("/");
    w.num(status.queue_limit);
    w.text(" requests=");
    w.num(state.requests);
    w.text(" bind=");
    w.num(state.bind_requests);
    w.text(" send=");
    w.num(state.send_requests);
    w.text(" recv=");
    w.num(state.recv_requests);
    w.text(" close=");
    w.num(state.close_requests);
    w.text(" dup=");
    w.num(state.duplicate_binds);
    w.text(" cleanup=");
    w.num(state.cleanup_runs);
    w.text("/");
    w.num(state.cleanup_handles);
    w.text(" drops=");
    w.num(status.drops);
    w.text(" lifecycle=");
    w.text(socketLifecycleName(status.last_lifecycle_cause));
    w.text(" bad_handle=");
    w.num(status.lifecycle_bad_handle);
    w.text(" last=");
    w.text(spanZ(status.last_error[0..]));
}

fn writeOperationText(w: *Writer, result: *const r4os.abi.NetServiceUdpResult, data: []const u8) void {
    w.text("op=");
    w.text(actionName(result.action));
    w.text(" result=");
    w.text(if (result.result == 0 and (result.flags & r4os.abi.net_service_udp_flag_ok) != 0) "ok" else "failed");
    w.text(" code=");
    w.signed(result.result);
    w.text(" status=");
    w.text(serviceStatusName(result.flags));
    if ((result.flags & r4os.abi.net_service_udp_flag_handle_valid) != 0) {
        w.text(" handle=");
        w.num(result.handle);
    }
    if ((result.flags & r4os.abi.net_service_udp_flag_remote_valid) != 0) {
        w.text(" remote=");
        w.ip(result.dest_ip);
        w.text(":");
        w.num(result.dest_port);
    } else if (result.dest_port != 0) {
        w.text(" port=");
        w.num(result.dest_port);
    }
    if (result.bytes != 0) {
        w.text(" bytes=");
        w.num(result.bytes);
    }
    if ((result.flags & r4os.abi.net_service_udp_flag_lifecycle_valid) != 0 or result.lifecycle_cause != r4os.abi.net_service_socket_lifecycle_unknown) {
        w.text(" lifecycle=");
        w.text(socketLifecycleName(result.lifecycle_cause));
    }
    if (data.len != 0) {
        w.text(" data=");
        w.text(data);
    }
    w.text(" last=");
    w.text(spanZ(result.last_error[0..]));
}

fn allocateFrontHandle(state: *ServiceState, owner_id: u32, backend_handle: u32, local_port: u16) ?u32 {
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (state.handles[i].used and state.handles[i].backend_handle == backend_handle and ownerMatches(state.handles[i].owner_id, owner_id)) return state.handles[i].handle;
    }
    i = 0;
    while (i < state.handles.len) : (i += 1) {
        if (state.handles[i].used) continue;
        const handle = nextFrontHandle(state);
        state.handles[i] = .{
            .used = true,
            .handle = handle,
            .backend_handle = backend_handle,
            .owner_id = owner_id,
            .local_port = local_port,
        };
        return handle;
    }
    return null;
}

fn nextFrontHandle(state: *ServiceState) u32 {
    const handle = state.next_handle;
    state.next_handle +%= 1;
    if (state.next_handle == 0) state.next_handle = 1;
    return handle;
}

fn resolveFrontHandle(state: *ServiceState, handle: u32, owner_id: u32) FrontLookup {
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        const entry = state.handles[i];
        if (!entry.used or entry.handle != handle) continue;
        if (!ownerMatches(entry.owner_id, owner_id)) {
            state.owner_mismatches +%= 1;
            return .{ .result = owner_mismatch_result, .last_error = "owner-mismatch" };
        }
        return .{ .ok = true, .index = i, .entry = entry, .result = 0, .last_error = "" };
    }
    return .{ .result = no_socket_result, .last_error = "no-socket" };
}

fn releaseFrontHandleAt(state: *ServiceState, index: usize) void {
    if (index >= state.handles.len) return;
    state.handles[index] = .{};
}

fn translateHandlePayload(payload: []const u8, backend_handle: u32) ?[]const u8 {
    if (payload.len > translated_payload.len or payload.len < 4) return null;
    copyBytes(translated_payload[0..payload.len], payload);
    writeLe32(translated_payload[0..], 0, backend_handle);
    return translated_payload[0..payload.len];
}

fn frontForPort(state: *const ServiceState, port: u16) ?usize {
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (state.handles[i].used and state.handles[i].local_port == port) return i;
    }
    return null;
}

fn cleanupService(app: *const App, state: *ServiceState, reason: []const u8) void {
    state.cleanup_runs +%= 1;
    var request: [4]u8 = .{0} ** 4;
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (!state.handles[i].used) continue;
        writeLe32(request[0..], 0, state.handles[i].backend_handle);
        _ = backendResult(app, r4os.abi.net_service_op_udp_close_result, request[0..], backend_result_data[0..]);
        state.handles[i] = .{};
        state.cleanup_handles +%= 1;
    }
    setLastError(state, reason);
}

fn closeBackendHandle(app: *const App, backend_handle: u32) void {
    var request: [4]u8 = .{0} ** 4;
    writeLe32(request[0..], 0, backend_handle);
    _ = backendResult(app, r4os.abi.net_service_op_udp_close_result, request[0..], backend_result_data[0..]);
}

fn noteResult(state: *ServiceState, result: *const r4os.abi.NetServiceUdpResult) void {
    state.last_result = result.result;
    if (result.handle != 0) state.last_handle = result.handle;
    if (result.dest_port != 0) state.last_port = result.dest_port;
    const last = spanZ(result.last_error[0..]);
    if (last.len != 0) {
        copyFixed(state.last_error[0..], last);
    } else {
        copyFixed(state.last_error[0..], if (result.result == 0) serviceStatusName(result.flags) else "failed");
    }
    rememberUdpLifecycle(state, result.lifecycle_cause);
}

fn frontHandleCount(state: *const ServiceState) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (state.handles[i].used) count += 1;
    }
    return count;
}

fn ownerMatches(entry_owner: u32, request_owner: u32) bool {
    return entry_owner == 0 or request_owner == 0 or entry_owner == request_owner;
}

fn resultOpForTextOp(op: u16) u16 {
    return switch (op) {
        r4os.abi.net_service_op_udp_bind => r4os.abi.net_service_op_udp_bind_result,
        r4os.abi.net_service_op_udp_sendto => r4os.abi.net_service_op_udp_sendto_result,
        r4os.abi.net_service_op_udp_recv => r4os.abi.net_service_op_udp_recv_result,
        r4os.abi.net_service_op_udp_close => r4os.abi.net_service_op_udp_close_result,
        else => 0,
    };
}

fn actionForOp(op: u16) u16 {
    return switch (op) {
        r4os.abi.net_service_op_udp_bind_result => r4os.abi.net_service_udp_action_bind,
        r4os.abi.net_service_op_udp_sendto_result => r4os.abi.net_service_udp_action_sendto,
        r4os.abi.net_service_op_udp_recv_result => r4os.abi.net_service_udp_action_recv,
        r4os.abi.net_service_op_udp_close_result => r4os.abi.net_service_udp_action_close,
        else => 0,
    };
}

fn actionName(action: u16) []const u8 {
    return switch (action) {
        r4os.abi.net_service_udp_action_bind => "bind",
        r4os.abi.net_service_udp_action_sendto => "sendto",
        r4os.abi.net_service_udp_action_recv => "recv",
        r4os.abi.net_service_udp_action_close => "close",
        else => "unknown",
    };
}

fn serviceStatusCode(flags: u32) u32 {
    return (flags & r4os.abi.net_service_status_mask) >> r4os.abi.net_service_status_shift;
}

fn serviceStatusName(flags: u32) []const u8 {
    return switch (serviceStatusCode(flags)) {
        r4os.abi.net_service_status_idle => "idle",
        r4os.abi.net_service_status_pending => "pending",
        r4os.abi.net_service_status_ok => "ok",
        r4os.abi.net_service_status_timeout => "timeout",
        r4os.abi.net_service_status_failed => "failed",
        r4os.abi.net_service_status_cancelled => "cancelled",
        r4os.abi.net_service_status_would_block => "would-block",
        else => "failed",
    };
}

fn withServiceStatus(flags: u32, status: u32) u32 {
    return (flags & ~r4os.abi.net_service_status_mask) | (status << r4os.abi.net_service_status_shift);
}

fn setUdpLifecycle(out: *r4os.abi.NetServiceUdpResult, cause: u32) void {
    if (cause == r4os.abi.net_service_socket_lifecycle_unknown) return;
    out.lifecycle_cause = cause;
    out.flags |= r4os.abi.net_service_udp_flag_lifecycle_valid;
}

fn lifecycleFromReason(reason: []const u8) u32 {
    if (contains(reason, "owner-mismatch")) return r4os.abi.net_service_socket_lifecycle_owner_mismatch;
    if (contains(reason, "no-socket") or contains(reason, "bad-handle") or contains(reason, "handle-full")) return r4os.abi.net_service_socket_lifecycle_bad_handle;
    if (contains(reason, "would-block")) return r4os.abi.net_service_socket_lifecycle_would_block;
    if (contains(reason, "timeout")) return r4os.abi.net_service_socket_lifecycle_timeout;
    if (contains(reason, "close")) return r4os.abi.net_service_socket_lifecycle_local_close;
    if (contains(reason, "drop")) return r4os.abi.net_service_socket_lifecycle_dropped;
    return r4os.abi.net_service_socket_lifecycle_unknown;
}

fn rememberUdpLifecycle(state: *ServiceState, cause: u32) void {
    if (cause == r4os.abi.net_service_socket_lifecycle_unknown) return;
    state.last_lifecycle_cause = cause;
}

fn recordUdpLifecycle(state: *ServiceState, cause: u32) void {
    rememberUdpLifecycle(state, cause);
    switch (cause) {
        r4os.abi.net_service_socket_lifecycle_closed => state.lifecycle_closed +%= 1,
        r4os.abi.net_service_socket_lifecycle_timeout => state.lifecycle_timeout +%= 1,
        r4os.abi.net_service_socket_lifecycle_local_close => state.lifecycle_local_close +%= 1,
        r4os.abi.net_service_socket_lifecycle_would_block => state.lifecycle_would_block +%= 1,
        r4os.abi.net_service_socket_lifecycle_bad_handle => state.lifecycle_bad_handle +%= 1,
        r4os.abi.net_service_socket_lifecycle_dropped => state.lifecycle_dropped +%= 1,
        else => {},
    }
}

fn socketLifecycleName(cause: u32) []const u8 {
    return switch (cause) {
        r4os.abi.net_service_socket_lifecycle_active => "active",
        r4os.abi.net_service_socket_lifecycle_closed => "closed",
        r4os.abi.net_service_socket_lifecycle_reset => "reset",
        r4os.abi.net_service_socket_lifecycle_timeout => "timeout",
        r4os.abi.net_service_socket_lifecycle_peer_gone => "peer-gone",
        r4os.abi.net_service_socket_lifecycle_local_abort => "local-abort",
        r4os.abi.net_service_socket_lifecycle_local_close => "local-close",
        r4os.abi.net_service_socket_lifecycle_pending_close => "pending-close",
        r4os.abi.net_service_socket_lifecycle_would_block => "would-block",
        r4os.abi.net_service_socket_lifecycle_bad_handle => "bad-handle",
        r4os.abi.net_service_socket_lifecycle_owner_mismatch => "owner-mismatch",
        r4os.abi.net_service_socket_lifecycle_listener => "listener",
        r4os.abi.net_service_socket_lifecycle_dropped => "dropped",
        else => "unknown",
    };
}

fn runPing(app: *const App) i32 {
    app.sys.println("UDPSVC ping");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) {
        app.sys.println("UDPSVC ping failed");
        return 1;
    }
    defer _ = app.sys.serviceClose(handle);

    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpStatus))) or header.status != r4os.abi.service_api_result_ok) {
        app.sys.println("UDPSVC ping failed");
        return 1;
    }
    var status = r4os.abi.NetServiceUdpStatus{};
    copyStruct(&status, selftest_status_response[0..]);
    if (status.magic != r4os.abi.net_service_udp_status_magic or status.version != r4os.abi.net_service_udp_status_version) {
        app.sys.println("UDPSVC ping failed");
        return 1;
    }
    app.sys.println("UDPSVC ping: OK");
    return 0;
}

fn runSelfTest(app: *const App) i32 {
    app.sys.println("UDPSVC selftest");
    if (!app.sys.hasFn("service_start")) return fail(app, "manager-api");
    if (!app.sys.hasFn("service_call")) return fail(app, "service-api");
    if (!localContractSelfTest(app)) return fail(app, "local-contract");

    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) return fail(app, "open");

    var header: r4os.abi.ServiceMessageHeader = .{};
    const status_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (status_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpStatus))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "status");
    var status = r4os.abi.NetServiceUdpStatus{};
    copyStruct(&status, selftest_status_response[0..]);
    if (status.magic != r4os.abi.net_service_udp_status_magic or status.version != r4os.abi.net_service_udp_status_version) return fail(app, "status-magic");
    if (status.max_sockets != front_handles_max or status.send_max == 0 or status.recv_max == 0) return fail(app, "status-limits");

    var text_response: [256]u8 = .{0} ** 256;
    const text_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_status, "", &header, text_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (text_got <= 0 or header.status != r4os.abi.service_api_result_ok) return fail(app, "text-status");
    if (!contains(text_response[0..@intCast(text_got)], "sockets=")) return fail(app, "text-sockets");

    var small: [8]u8 = .{0} ** 8;
    const bad_op = app.sys.serviceCall(handle, 0xFFFF, "", &header, small[0..], app.sys.ticksFromMilliseconds(100));
    if (bad_op < 0 or header.status != r4os.abi.service_api_result_bad_op) return fail(app, "bad-op");

    const structured_port: u16 = 65054;
    var bind_request: [2]u8 = .{0} ** 2;
    writeLe16(bind_request[0..], 0, structured_port);
    const bind_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_bind_result, bind_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (bind_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "bind");
    var result = r4os.abi.NetServiceUdpResult{};
    copyStruct(&result, selftest_result_response[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.result != 0 or result.action != r4os.abi.net_service_udp_action_bind or (result.flags & r4os.abi.net_service_udp_flag_handle_valid) == 0) return fail(app, "bind-result");
    const udp_handle = result.handle;

    const dup_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_bind_result, bind_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (dup_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "duplicate-bind");
    copyStruct(&result, selftest_result_response[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.result == 0 or result.action != r4os.abi.net_service_udp_action_bind) return fail(app, "duplicate-bind-result");

    var recv_request: [6]u8 = .{0} ** 6;
    writeLe32(recv_request[0..], 0, udp_handle);
    writeLe16(recv_request[0..], 4, 32);
    const recv_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_recv_result, recv_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (recv_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "recv");
    copyStruct(&result, selftest_result_response[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.result != 0 or result.action != r4os.abi.net_service_udp_action_recv or serviceStatusCode(result.flags) != r4os.abi.net_service_status_would_block) return fail(app, "recv-would-block");

    var send_request: [16]u8 = .{0} ** 16;
    writeLe32(send_request[0..], 0, udp_handle);
    send_request[4] = 127;
    send_request[5] = 0;
    send_request[6] = 0;
    send_request[7] = 1;
    writeLe16(send_request[0..], 8, 9);
    send_request[10] = 'u';
    send_request[11] = 'd';
    send_request[12] = 'p';
    const send_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_sendto_result, send_request[0..13], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (send_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "sendto");
    copyStruct(&result, selftest_result_response[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.action != r4os.abi.net_service_udp_action_sendto or (result.flags & r4os.abi.net_service_udp_flag_handle_valid) == 0 or result.requested_bytes != 3) return fail(app, "sendto-result");

    var close_request: [4]u8 = .{0} ** 4;
    writeLe32(close_request[0..], 0, udp_handle);
    const close_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_close_result, close_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (close_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "close");
    copyStruct(&result, selftest_result_response[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.result != 0 or result.action != r4os.abi.net_service_udp_action_close) return fail(app, "close-result");

    const restart_port: u16 = 65055;
    writeLe16(bind_request[0..], 0, restart_port);
    const restart_bind = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_bind_result, bind_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (restart_bind != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "restart-bind");
    copyStruct(&result, selftest_result_response[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.result != 0) return fail(app, "restart-bind-result");

    _ = app.sys.serviceClose(handle);
    var info: r4os.abi.ServiceInfo = .{};
    const restart = app.sys.serviceRestart(service_name, &info);
    if (restart != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running) return fail(app, "restart");
    if (!ensureRunningAndOpen(app, &handle)) return fail(app, "reopen");
    defer _ = app.sys.serviceClose(handle);

    const after_status = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (after_status != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpStatus))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "after-status");
    copyStruct(&status, selftest_status_response[0..]);
    if (status.active_sockets != 0) return fail(app, "restart-cleanup");

    writeLe32(recv_request[0..], 0, 0xCAFE5510);
    const stale_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_udp_recv_result, recv_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (stale_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceUdpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "stale");
    copyStruct(&result, selftest_result_response[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    if (result.result == 0 or result.action != r4os.abi.net_service_udp_action_recv) return fail(app, "stale-result");

    app.sys.println("UDPSVC selftest: OK");
    return 0;
}

fn localContractSelfTest(app: *const App) bool {
    var state = ServiceState{};
    setLastError(&state, "selftest");
    const front = allocateFrontHandle(&state, 11, 41, 65056) orelse return false;
    if (front == 0 or frontHandleCount(&state) != 1) return false;
    if (resolveFrontHandle(&state, front, 22).result != owner_mismatch_result) return false;
    const ok_lookup = resolveFrontHandle(&state, front, 11);
    if (!ok_lookup.ok or ok_lookup.entry.backend_handle != 41 or ok_lookup.entry.local_port != 65056) return false;
    if (frontForPort(&state, 65056) == null) return false;
    releaseFrontHandleAt(&state, ok_lookup.index);
    if (frontHandleCount(&state) != 0) return false;

    var result = localError(app, &state, r4os.abi.net_service_op_udp_bind_result, 0, bind_in_use_result, "bind-in-use").result;
    if (result.magic != r4os.abi.net_service_udp_result_magic or result.result != bind_in_use_result) return false;
    if (serviceStatusCode(result.flags) != r4os.abi.net_service_status_failed) return false;
    result = ownerMismatch(&state, r4os.abi.net_service_op_udp_close_result, 9, 65057).result;
    if (result.result != owner_mismatch_result or serviceStatusCode(result.flags) != r4os.abi.net_service_status_failed) return false;

    service_status_reply = makeStatus(app, &state, 11);
    if (service_status_reply.magic != r4os.abi.net_service_udp_status_magic or service_status_reply.max_sockets != front_handles_max) return false;

    var buf: [256]u8 = .{0} ** 256;
    var w = Writer{ .out = buf[0..] };
    writeStatusText(&w, &state, &service_status_reply);
    return contains(w.slice(), "sockets=");
}

fn ensureRunningAndOpen(app: *const App, out_handle: *u32) bool {
    var info: r4os.abi.ServiceInfo = .{};
    const status = app.sys.serviceStatus(service_name, &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = app.sys.serviceStart(service_name, &info);
        if (start != r4os.abi.service_api_result_ok) return false;
    }
    var tick: u32 = 0;
    while (tick < 160) : (tick += 1) {
        const open_rc = app.sys.serviceOpen(service_name, &info);
        if (open_rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            out_handle.* = info.handle;
            return true;
        }
        app.sys.sleepTicks(1);
    }
    return false;
}

fn fail(app: *const App, label: []const u8) i32 {
    app.sys.write("UDPSVC selftest FAILED: ");
    app.sys.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn readLe16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readLe32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn writeLe16(out: []u8, offset: usize, value: u16) void {
    out[offset] = @truncate(value & 0x00FF);
    out[offset + 1] = @truncate(value >> 8);
}

fn writeLe32(out: []u8, offset: usize, value: u32) void {
    out[offset] = @truncate(value & 0x000000FF);
    out[offset + 1] = @truncate((value >> 8) & 0x000000FF);
    out[offset + 2] = @truncate((value >> 16) & 0x000000FF);
    out[offset + 3] = @truncate((value >> 24) & 0x000000FF);
}

fn copyStruct(out: anytype, data: []const u8) void {
    const out_bytes: [*]u8 = @ptrCast(out);
    const size = @sizeOf(@TypeOf(out.*));
    const len = @min(size, data.len);
    var i: usize = 0;
    while (i < len) : (i += 1) out_bytes[i] = data[i];
}

fn copyBytes(out: []u8, value: []const u8) void {
    var i: usize = 0;
    const len = @min(out.len, value.len);
    while (i < len) : (i += 1) out[i] = value[i];
}

fn copyFixed(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(out.len - 1, value.len);
    if (len != 0) copyBytes(out[0..len], value[0..len]);
}

fn setLastError(state: *ServiceState, value: []const u8) void {
    copyFixed(state.last_error[0..], value);
}

fn spanZ(data: []const u8) []const u8 {
    var len: usize = 0;
    while (len < data.len and data[len] != 0) : (len += 1) {}
    return data[0..len];
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

const Writer = struct {
    out: []u8,
    pos: usize = 0,

    fn text(self: *Writer, value: []const u8) void {
        if (self.pos >= self.out.len) return;
        const len = @min(value.len, self.out.len - self.pos);
        if (len != 0) copyBytes(self.out[self.pos .. self.pos + len], value[0..len]);
        self.pos += len;
    }

    fn num(self: *Writer, value: anytype) void {
        var buf: [32]u8 = undefined;
        var v: u64 = @intCast(value);
        var i: usize = buf.len;
        if (v == 0) {
            self.text("0");
            return;
        }
        while (v != 0 and i > 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
        self.text(buf[i..]);
    }

    fn signed(self: *Writer, value: i32) void {
        if (value < 0) {
            self.text("-");
            self.num(@as(u32, @intCast(-value)));
        } else {
            self.num(@as(u32, @intCast(value)));
        }
    }

    fn ip(self: *Writer, value: [4]u8) void {
        self.num(value[0]);
        self.text(".");
        self.num(value[1]);
        self.text(".");
        self.num(value[2]);
        self.text(".");
        self.num(value[3]);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.out[0..self.pos];
    }
};
