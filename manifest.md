# GGLang Manifesto & Technical Specification
A Modern, Functional, Indentation-Based Scripting Language

GGLang is a lightweight scripting language designed to combine **Lua's embedding agility**, **Python's visual elegance**, and **Rust/OCaml's functional safety**. It aims to be the ultimate language for application configuration, plugins, and embedded scripting ecosystems.

---

## 1. Core Design Philosophy

1. **Readability Over Noise:** Indentation specifies block scopes (`:` and whitespace). No curly braces `{}` or semicolons `;`.
2. **Immutable by Default:** Value mutation must be explicit. Variables declared with `let` cannot change. State tracking uses `mut`.
3. **Expression-Oriented:** Everything is an expression and returns a value. `if`, `match`, and block scopes can be evaluated and assigned.
4. **Unified Data Structures:** Like Lua, complex structures are represented by a single, powerful concept: the **Table**.
5. **Robust Data Deconstruction:** Algebraic Data Types (ADTs) and pattern matching eliminate deeply nested conditional statements.
6. **Functional Data Pipelines:** State mutation loops (`while`) are discouraged in favor of standard functional iterators (`.map`, `.filter`, `.reduce`).
7. **Host-First Architecture:** Designed from day one to be seamlessly embedded in host environments (like Zig or C) with zero-cost data mapping.

---

## 2. Syntax Specification & Code Demonstrations

### 2.1 Variables & Scope
Variables are immutable by default. Re-binding (shadowing) is allowed in nested scopes without altering the outer value.

```python
# Immutable assignment
let developer = "Imad"

# Mutable assignment requires the 'mut' keyword
mut performance_score = 98
performance_score = 100

# Everything is an expression
let access_level =
    let base = 10
    let modifier = 5
    base + modifier # Implicitly returned

print(access_level) # Outputs: 15
```

### 2.2 Unified Structures: Tables
Tables serve as dictionaries, records, and arrays.

```python
# Defining a table record
let user = {
    username: "pepedinho",
    role: "admin",
    active: true,
    stats: {
        commits: 423,
        lines_written: 15420
    }
}

# Accessing fields via dot notation
print(user.username)
print(user.stats.commits)
```

### 2.3 Algebraic Data Types (ADTs)
GGLang supports tagged unions (variants) with associated payloads, enabling domain modeling without complex class hierarchies.

```python
# A simple optional wrapper
type Option =
    | Some(value)
    | None

# Network event state variants
type NetworkEvent =
    | Connected(ip_address, port)
    | MessageReceived(author, payload)
    | Transmitting
    | Disconnected(reason)
```

### 2.4 Pattern Matching
The `match` expression is the central mechanism for control flow. It forces exhaustive checking of variants and deconstructs data atomically.

```python
fn handle_network(event):
    let log_message = match event:
        Connected(ip, port) => 
            "Established connection to " + ip + ":" + port
        MessageReceived("Zorro", content) => 
            "High priority message from Zorro: " + content
        MessageReceived(user, content) => 
            "Message from " + user + ": " + content
        Transmitting => 
            "Data transfer in progress..."
        Disconnected(reason) => 
            "Connection dropped due to: " + reason
            
    print(log_message)
```

### 2.5 Functions & Closures
Functions are first-class citizens. They can be anonymous, assigned to variables, passed as parameters, and capture their lexical environment (closures).

```python
# Standard function declaration
fn multiply(a, b):
    a * b # Implicit return of the final expression

# Higher-order function accepting a closure
fn apply_twice(f, value):
    f(f(value))

let increment = fn(x): x + 1
print(apply_twice(increment, 5)) # Outputs: 7

# Closure capturing external state
fn make_adder(x):
    return fn(y): x + y

let add_five = make_adder(5)
print(add_five(10)) # Outputs: 15
```

### 2.6 Functional Iterators (Pipelines)
To maintain the functional paradigm and avoid imperative loops (`while`) and mutable state (`mut`), GGLang implements standard iterators directly on Tables.

```python
let users = {
    { name: "Alice", age: 25, active: true },
    { name: "Bob", age: 17, active: true },
    { name: "Charlie", age: 30, active: false }
}

# Method chaining allows for elegant, immutable data transformations
let active_adult_names = users
    .filter(fn(u): u.active and u.age >= 18)
    .map(fn(u): u.name)

print(active_adult_names) # Outputs: {"Alice"}

# Reduce for data aggregation
let total_age = users.reduce(0, fn(acc, u): acc + u.age)
```

### 2.7 Control Flow
While functional constructs are preferred, imperative tools are available for explicit iteration over state when absolutely necessary.

```python
# Standard If/Else Expression
let system_status = if score > 90: "Optimal" else: "Degraded"

# While Loop for explicit mutations (discouraged over map/reduce)
fn compute_factorial(n):
    mut result = 1
    mut current = n
    
    while current > 0:
        result = result * current
        current = current - 1
        
    return result
```

---

## 3. Core Architectural Pipeline

Building the GGLang interpreter in Zig follows a structured, step-by-step pipeline:

```
[ Source Code ] 
       │
       ▼
 1. Lexical Analysis (Lexer) ──► Transforms string into raw `Tokens` (handles indentation)
       │
       ▼
 2. Syntactic Analysis (Parser) ─► Generates the Abstract Syntax Tree (`AST`)
       │
       ▼
 3. Evaluation Engine (Tree-Walk) ─► Executes AST branches in-memory with environment scopes
       │
       ▼
 [ Future Bytecode Optimization ] ─► Compiles AST to bytecode, executed by a high-speed VM
```

---

## 4. Implementation Goals & Deliverables

* **Phase 1: Lexer Implementation** Complete token extraction. Must emit `Indent`, `Dedent`, and `NewLine` tokens flawlessly without doing runtime allocations.
* **Phase 2: Parser & AST Design** Turn token strings into valid Zig structural nodes (`LetNode`, `FnNode`, `MatchNode`). Use memory arenas to drop whole file structures cleanly.
* **Phase 3: Scope & Environment Trees** Map variables dynamically, supporting lexical scoping and closure capture tables.
* **Phase 4: Table Implementations** Optimize hash-map records inside the Zig memory workspace. Build the standard library (`.map`, `.filter`, `.reduce`).
* **Phase 5: Native Host Interoperability** Build cross-bindings so Zig functions can be invoked inside GGLang configuration scripts and vice versa.
