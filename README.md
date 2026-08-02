```
 │ _   _ ___  ___
 │| | | |   \| _ \___ __ __ _ _ _
 │| |_| | |) |  _/ -_) _/ _` | ' \
 │ \___/|___/|_| \___\__\__,_|_||_|
 ╰───────────────────────────────────
```

**LAN peer discovery and advertisement service using UDP broadcast/relay.**

> Because every network needs at least one overly enthusiastic nut broadcasting on UDP.
## Overview

**Find other players on your local network. No server required.**

UDPecan is a small Godot script that lets game instances discover each other on a LAN. It’s especially useful when you want to test multiplayer by running several copies of your game on the *same* computer.

## What it does

- Automatically finds other players on the same Wi-Fi / local network - Lets you advertise a game session (or any custom data) - Handles the case where the “host” machine leaves — someone else can take over - Works when you run multiple game windows on one development machine (this is the part most other discovery tools struggle with)

## How it works (simple version)

One instance becomes the **Leader**. Everyone else becomes a **Peer**.

- The Leader sits on a known port and acts as a post office. - Peers send their “I’m here” messages and advertisements to the Leader. - The Leader forwards those messages to everyone else.

If the Leader disappears, any Peer that is allowed to can promote itself and become the new Leader. This is what makes testing with multiple local instances painless.

## Features

- **Automatic discovery** — other players appear and disappear without manual IP entry
- **Custom advertisements** — publish whatever data you want (game name, player count, map, etc.)
- **Works on one machine** — spin up several clients on your dev PC and they can still find each other
- **Leader failover** — if the current host leaves, another instance can take over
- **Clean shutdown** — instances announce when they’re leaving so others don’t wait for a timeout

---
## Installation

UDPecan is not an addon, its just a script.

1. Copy `udpecan.gd` into your project (e.g. `res://addons/udpecan/` or wherever you keep scripts).
2. Attach the script to a `Node` in a scene.

## Quick Start

```gdscript
# 1. Attach UDPecan to a scene node
# 2. Configure exported properties in the inspector (or via code)
$UDPecan.leader_port = 54323
$UDPecan.bind_address = "0.0.0.0"
$UDPecan.allow_promotion = true
$UDPecan.start_on_ready = true
$UDPecan.advertise_presence = true

# 3. Connect signals
$UDPecan.peer_appeared.connect(_on_peer_appeared)
$UDPecan.advert_received.connect(_on_advert_received)
$UDPecan.leader_updated.connect(_on_leader_updated)

# 4. Start (if start_on_ready is false)
$UDPecan.start()
```

## Exported Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `start_on_ready` | `bool` | `false` | Automatically call `start()` when the node is ready. |
| `allow_promotion` | `bool` | `false` | Allow this instance to become the leader if the current leader disappears. |
| `maintenance_interval` | `int` (ms) | `6000` | How often the maintenance timer runs. |
| `expiration_threshold` | `int` (ms) | `9000` | Time after last-seen before a peer or advertisement is considered expired. |
| `bind_address` | `String` | `"0.0.0.0"` | Address to bind the UDP socket to. Use `"127.0.0.1"` for local testing. |
| `leader_port` | `int` | `54323` | Fixed port the leader binds to. Peers send heartbeats here. |
| `advertise_presence` | `bool` | `false` | Periodically broadcast basic presence information. |
| `local_ident` | `Variant` | `null` | Unique identity for this host. Auto-generated if left null. |
| `custom_presence_content` | `Variant` | `null` | Optional custom data attached to presence broadcasts. |

Read-only (after binding):

- `local_port`
- `local_ip`

## Signals

### Lifetime
| Signal | Description |
|--------|-------------|
| `started` | Emitted when `start()` finishes. |
| `bound_to_port(port: int, as_leader: bool)` | Emitted when the UDP socket successfully binds. |
| `promoted` | Emitted when this instance becomes the leader. |
| `stopping` | Emitted at the beginning of `stop()`. |
| `stopped` | Emitted when `stop()` completes. |

### Discovery & Presence
| Signal | Description |
|--------|-------------|
| `leader_updated(leader_ident: Variant, msg: Dictionary)` | Leader information received or updated. |
| `peer_appeared(peer_ident: Variant, peer_dict: Dictionary)` | A new peer was detected. |
| `peer_updated(peer_ident: Variant, peer_dict: Dictionary)` | An existing peer sent updated information. |
| `peer_vanished(peer_ident: Variant)` | A peer expired or sent a shutdown notice. |

### Advertisements
| Signal | Description |
|--------|-------------|
| `advert_received(msg_ident: Variant, msg: Dictionary)` | A new advertisement was received. |
| `advert_updated(advert_ident: Variant, msg: Dictionary)` | An existing advertisement was updated. |
| `advert_expired(advert_ident: Variant)` | An advertisement timed out. |

### Local Posts (advertisements you publish)
| Signal | Description |
|--------|-------------|
| `post_added(post_ident: Variant, kind: StringName, post: Variant)` | A new local advertisement was posted. |
| `post_updated(post_ident: Variant, kind: StringName, post: Variant)` | A local advertisement was updated. |
| `post_removed(post_ident: Variant)` | A local advertisement was removed. |

## Public Methods

### Lifecycle
```gdscript
func start() -> void
func stop() -> void
func is_leader() -> bool
```

### Publishing Advertisements
```gdscript
func post_advert(content: Variant, kind: StringName = &"", ad_id: Variant = null) -> Variant
func has_post(ad_id: Variant) -> bool
func get_post(ad_id: Variant) -> Variant
func get_posts() -> Dictionary
func modify_post(ad_id: Variant, kind: StringName, content: Variant) -> void
func remove_post(ad_id: Variant) -> void
func clear_posts() -> void
```

### Received Advertisements
```gdscript
func get_advert(advert_ident: Variant) -> Dictionary
func get_adverts() -> Dictionary
func remove_advert(advert_ident: Variant) -> void
func clear_adverts() -> void
```

### Encoding
```gdscript
func assign_encoding(kind: StringName, encoder: Callable, decoder: Callable) -> void
```

---
## Advertisement Message Structure

When you receive an advertisement via `advert_received`, the `msg` dictionary looks like this:

```gdscript
{
    type    : int,          # MsgType flags
    ip      : String,       # IP of the original advertiser
    port    : int,          # Port of the original advertiser
    ident   : Variant,      # Identity of the sender
    ad_id   : Variant,      # Unique advertisement ID
    kind    : StringName,   # Optional advertisement kind
    content : Variant,      # The (possibly decoded) payload
    last_seen : int         # Timestamp (ms)
}
```

---

## How It Works

1. On `start()`, the node first tries to bind to `leader_port` (if `allow_promotion` is true).
2. If the port is already taken, it binds to a random ephemeral port and becomes a **Peer**.
3. Peers periodically send heartbeats to the leader.
4. The leader relays advertisements and presence information to all known peers.
5. If the leader stops responding, peers with `allow_promotion = true` will attempt to take over the role.

---

## Custom Advertisement Encoding

By default advertisements are serialized with `var_to_bytes` / `bytes_to_var`.  
You can register custom encoders/decoders per kind:

```gdscript
func _ready():
    $UDPecan.assign_encoding(&"my_game_data",
        func(data): return JSON.stringify(data).to_utf8_buffer(),
        func(bytes): return JSON.parse_string(bytes.get_string_from_utf8())
    )
```

---

## Notes

- Uses `PacketPeerUDP` + manual `var_to_bytes` / `bytes_to_var`.
- Leader relays messages — peers never broadcast directly to each other.
- Single-host multi-process testing is supported by using different ports.
- Naming convention:
  - **sender** = last hop (matches Godot’s API)
  - **source** = original origin before any relay

---

## License

MIT License © 2026 Samuel Nicholas