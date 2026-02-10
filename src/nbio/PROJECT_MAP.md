# nbio Project Map

A comprehensive guide to the **nbio** (Non-Blocking I/O) library for the Odin programming language.

---

## Project Overview

**nbio** is a cross-platform non-blocking I/O and event loop abstraction library. It provides asynchronous operations for network I/O, file system operations, timeouts, and polling.

### Platform Support

| Platform | Status | Backend |
|----------|--------|---------|
| Linux | ✅ Fully supported | io_uring |
| macOS (Darwin) | ✅ Fully supported | kqueue |
| FreeBSD | ✅ Fully supported | kqueue |
| OpenBSD | ✅ Fully supported | kqueue |
| NetBSD | ✅ Fully supported | kqueue |
| Windows | ✅ Fully supported | IOCP |
| Others | ⚠️ Limited | Stub implementation |

### Key Configuration

- `NBIO_MAX_USER_ARGUMENTS` (default: 4): Maximum user arguments for polymorphic callbacks
- `NBIO_DEBUG` (default: false): Enable debug logging
- `ODIN_NBIO_QUEUE_SIZE` (default: 256 on POSIX, 2048 on Linux): Event queue size

---

## Quick Navigation

### Core Files
- [nbio.odin](#nbioodin) - Main public API and Event Loop
- [ops.odin](#opsodin) - All I/O operation definitions
- [net.odin](#netodin) - Networking type aliases
- [doc.odin](#docodin) - Package documentation and examples

### Implementation Files
- [impl.odin](#implodin) - Common implementation helpers
- [impl_linux.odin](#impl_linuxodin) - Linux io_uring implementation
- [impl_posix.odin](#impl_posixodin) - POSIX kqueue implementation
- [impl_windows.odin](#impl_windowsodin) - Windows IOCP implementation

### Supporting Files
- [mpsc.odin](#mpscodin) - Multi-producer single-consumer queue
- [errors*.odin](#error-files) - Error handling for all platforms

---

## File Details

### nbio.odin
**Purpose**: Main public API - Entry point for using the library  
**Lines**: ~432  
**Key Contents**:
- `Event_Loop` struct - One per thread, reference-counted
- `Operation` struct - Unified representation of any async operation
- Core functions:
  - `acquire_thread_event_loop()` - Get/create event loop for current thread
  - `tick()` - Process completed operations and invoke callbacks
  - `run()` - Run event loop until stopped
- Thread management and event loop lifecycle

**When to read**: Start here to understand how to use the library

---

### ops.odin
**Purpose**: All I/O operation definitions and polymorphic variants  
**Lines**: ~1,500+  
**Key Contents**:
- Operation type definitions for:
  - **Network**: `accept`, `dial`, `send`, `recv`
  - **File**: `read`, `write`, `open`, `stat`, `sendfile`
  - **Utility**: `timeout`, `poll`, `close`
- Polymorphic variants for type-safe user data:
  - `accept_poly`, `dial_poly`, `send_poly`, `recv_poly`, etc.
- Operation state tracking and callback management
- Buffer management for scatter/gather I/O

**When to read**: When implementing specific I/O operations

---

### net.odin
**Purpose**: Type aliases for networking types  
**Lines**: ~40  
**Key Contents**:
- Re-exports from `core:net`:
  - `Socket` type
  - `Endpoint` type
  - `Address` type
  - `Network` type

**When to read**: Reference for networking types used throughout the library

---

### doc.odin
**Purpose**: Package documentation with usage examples  
**Lines**: ~214  
**Key Contents**:
- Design explanations and philosophy
- Usage examples for common patterns
- Architecture overview
- Best practices

**When to read**: To understand design decisions and see code examples

---

### impl.odin
**Purpose**: Common implementation helpers and utilities  
**Lines**: ~319  
**Key Contents**:
- Buffer management utilities
- Debugging helpers (when `NBIO_DEBUG` is enabled)
- Common operation setup and teardown
- Platform-agnostic helper functions

**When to read**: When diving into implementation details or debugging

---

### mpsc.odin
**Purpose**: Multi-producer single-consumer queue  
**Lines**: ~63  
**Key Contents**:
- Lock-free queue for cross-thread operation submission
- Allows worker threads to enqueue operations to I/O threads
- Used internally by platform implementations

**When to read**: When understanding cross-thread operation submission

---

## Platform-Specific Implementation Files

### impl_linux.odin
**Platform**: Linux  
**Lines**: ~1,466  
**Backend**: io_uring  
**Key Contents**:
- io_uring setup and configuration
- Operation submission and completion handling
- Platform-specific optimizations
- Direct Linux system call integration

**When to read**: Linux-specific implementation details, io_uring internals

---

### impl_posix.odin
**Platform**: Darwin, FreeBSD, OpenBSD, NetBSD  
**Lines**: ~1,401  
**Backend**: kqueue  
**Key Contents**:
- kqueue setup and event handling
- Common POSIX implementation shared across BSDs
- Socket and file descriptor management

**When to read**: BSD/macOS implementation details, kqueue internals

---

### impl_posix_darwin.odin
**Platform**: macOS (Darwin)  
**Key Contents**:
- Darwin-specific sendfile implementation
- Darwin-specific error handling

---

### impl_posix_freebsd.odin
**Platform**: FreeBSD  
**Key Contents**:
- FreeBSD-specific sendfile implementation
- FreeBSD-specific error handling

---

### impl_posix_openbsd.odin
**Platform**: OpenBSD  
**Key Contents**:
- OpenBSD-specific error handling

---

### impl_posix_netbsd.odin
**Platform**: NetBSD  
**Key Contents**:
- NetBSD-specific error handling

---

### impl_windows.odin
**Platform**: Windows  
**Lines**: ~1,849  
**Backend**: IOCP (I/O Completion Ports)  
**Key Contents**:
- IOCP setup and configuration
- Windows-specific handle management
- Overlapped I/O operations
- Windows socket and file operations

**When to read**: Windows-specific implementation details, IOCP internals

---

### impl_others.odin
**Platform**: Other/Unsupported platforms  
**Lines**: ~219  
**Key Contents**:
- Stub implementations that return errors
- Fallback for unsupported platforms

---

## Error Files

### errors.odin
**Purpose**: Common error types and string functions  
**Contents**:
- Base error type definitions
- Error code to string conversion utilities

---

### errors_linux.odin
**Platform**: Linux  
**Contents**:
- Linux errno mappings to nbio error codes

---

### errors_posix.odin
**Platform**: POSIX (BSDs/macOS)  
**Contents**:
- POSIX errno mappings to nbio error codes

---

### errors_windows.odin
**Platform**: Windows  
**Contents**:
- Windows System_Error mappings to nbio error codes

---

### errors_others.odin
**Platform**: Other platforms  
**Contents**:
- Generic error codes for unsupported platforms

---

## Architecture Overview

### Core Concepts

1. **Event Loop**: One per thread, reference-counted. Manages all I/O operations and their callbacks.
   - Created via `acquire_thread_event_loop()`
   - Processes completions via `tick()` or `run()`

2. **Operations**: Unified `Operation` struct representing any async operation
   - Contains operation-specific data (socket, buffer, offset, etc.)
   - Has a callback for completion notification
   - Supports optional timeouts

3. **Callbacks**: All operations use callbacks for completion notification
   - Callbacks are **guaranteed** to be invoked in a later tick, never synchronously
   - Polymorphic variants allow type-safe user data

4. **Thread Safety**:
   - I/O threads (with event loops) execute operations
   - Worker threads can enqueue operations to I/O threads via MPSC queue

### File Relationships

```
nbio.odin (public API)
    |
    +---> impl.odin (common implementation)
    |       +---> mpsc.odin (cross-thread queue)
    |
    +---> Platform-specific implementations (compile-time selection):
            |
            +---> impl_linux.odin (Linux + errors_linux.odin)
            +---> impl_posix.odin + impl_posix_*.odin (BSDs/macOS + errors_posix.odin)
            +---> impl_windows.odin (Windows + errors_windows.odin)
            +---> impl_others.odin (fallback + errors_others.odin)
```

### Design Features

- **Positional I/O**: Read/write operations use explicit offsets (pread/pwrite style), not file positions
- **Timeouts**: Optional per-operation timeouts with automatic cancellation
- **Polymorphic variants**: Type-safe user data in callbacks (`accept_poly`, `send_poly`, etc.)
- **Buffer management**: Internal buffer handling for scatter/gather I/O
- **Cross-thread execution**: Operations can be submitted from worker threads to I/O threads

---

## Usage Patterns

### Basic Event Loop Usage
```odin
// See doc.odin for complete examples
loop := nbio.acquire_thread_event_loop()
nbio.run(loop)  // or nbio.tick(loop) for manual control
```

### Operation Types

| Operation | Description | Callback Data |
|-----------|-------------|---------------|
| `accept` | Accept incoming TCP connection | New socket and endpoint |
| `dial` | Connect to remote endpoint | Connected socket |
| `send` | Send data over socket | Bytes sent |
| `recv` | Receive data from socket | Bytes received |
| `read` | Read from file at offset | Bytes read |
| `write` | Write to file at offset | Bytes written |
| `open` | Open a file | File handle |
| `stat` | Get file metadata | File info |
| `sendfile` | Efficient file-to-socket transfer | Bytes sent |
| `timeout` | Delayed callback | None |
| `poll` | Wait for file descriptor readiness | Ready status |
| `close` | Close socket or file | None |

---

## Statistics

- **Total files**: 21
- **Total lines**: ~7,500+ lines of Odin code
- **Main implementation**: ~4,500 lines across platform-specific files
- **Public API**: ~2,000 lines

---

## Additional Files

### remote_version_tracker.txt
Tracks upstream version from https://github.com/odin-lang/Odin/tree/master/core/nbio  
Last applied: commit `0a05ff0`

---

## Getting Started

1. **Read**: `doc.odin` for overview and examples
2. **Reference**: `nbio.odin` for main API
3. **Implement**: Use `ops.odin` for operation-specific details
4. **Debug**: Check `impl.odin` for utilities and `errors_*.odin` for error handling
5. **Platform specifics**: Reference `impl_*.odin` files for your target platform

---

*Generated from project analysis*
