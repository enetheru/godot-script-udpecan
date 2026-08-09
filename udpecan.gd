@tool
extends Node
##[codeblock lang=text]
##│ _   _ ___  ___
##│| | | |   \| _ \___ __ __ _ _ _
##│| |_| | |) |  _/ -_) _/ _` | ' \
##│ \___/|___/|_| \___\__\__,_|_||_|
##╰───────────────────────────────────
##[/codeblock]LAN peer discovery and advertisement service using UDP broadcast/relay.
##
## UDPecan — because every network needs at least one overly enthusiastic nut
## broadcasting on UDP.
##[br][br]
## This node provides automatic LAN server discovery and advertisement.
## [br]It supports two roles:
## [br]• [b]Leader[/b] — binds to a fixed port and relays messages between peers
## [br]• [b]Peer[/b]   — sends heartbeats to the leader and receives relayed messages
##[br][br]
## [b]Features:[/b]
## [br]• Peer presence detection with timeout
## [br]• Advertisement publishing and receiving (with custom data)
## [br]• Automatic leader election/promotion when the leader disappears
## [br]• Graceful shutdown announcement
## [br]• Relaying of presence and advertisements via the leader
##[br][br]
## [b]Main usage:[/b]
## [br]1. Attach this node to a scene
## [br]2. Set exported properties ([member leader_port], [member bind_address], etc.)
## [br]3. Call [method start] or set [member start_on_ready] to [code]true[/code]
## [br]4. Connect to signals ([signal peer_appeared], [signal advert_received], etc.)
##[br][br]
## Advertisement data format can be customized by setting the [Callable]s:
## [member advertisement_encoder] / [member advertisement_decoder]
##[br][br]
## [b]Important implementation notes:[/b]
## [br]• Uses [PacketPeerUDP] with manual [method @GlobalScope.var_to_bytes] /
## [method @GlobalScope.bytes_to_var]
## [br]• Leader relays messages — peers never broadcast directly to each other
## [br]• Single-host/multi-process testing is supported via different ports
##[br][br]
## [b]Notes on naming:[/b]
## [br]• "sender" is reserved for the last hop, and is congruent with godot's api
## [br]• "source" is reserved for the origin, before any relay
##[br][br]
## [b]TODO List:[/b]
##[br][color=goldenrod]TODO[/color]: per-advertisement custom timeouts (nice-to-have, not critical)
##[br][color=goldenrod]TODO[/color]: batch relay packets
##[br][color=goldenrod]TODO[/color]: Cache packets to avoid re-building them
##[br][color=goldenrod]TODO[/color]: add channels, to reduce overall traffic both internally and externally
##[br][color=goldenrod]TODO[/color]: Send a notification packet when removing posts.
##[br][color=goldenrod]TODO[/color]: Add a pause/resume, that maintains the port binding, but ignores packets.

# Versioning and source location
const V:String = "0.2.0"
const S:String = "https://github.com/enetheru/godot-script-udpecan"
const U:String = "https://raw.githubusercontent.com/enetheru/godot-script-udpecan/main/version.json"
const VERSION_CHECK_ENABLED:bool = true

## Packet Types for identifying information
enum MsgType {
	PEER     = 0x01, ## The Leader informtion
	LEADER   = 0x02, ## Peer Information sent only from the Leader
	ADVERT   = 0x04, ## Generic Advertisements
	RELAY    = 0x08, ## Relayed Advertisements
	SHUTDOWN = 0x10, ## Explicit notification of a Peer's exit
}

enum Dest {
	NONE,
	ERROR,
	LEADER,
	PEER,
	BROADCAST,
}

##[codeblock]
##│ _   _ ___  ___                    __  __
##│| | | |   \| _ \___ __ __ _ _ _   |  \/  |___ __ _
##│| |_| | |) |  _/ -_) _/ _` | ' \ _| |\/| (_-</ _` |
##│ \___/|___/|_| \___\__\__,_|_||_(_)_|  |_/__/\__, |
##│                                             |___/
##╰─────────────────────────────────────────────────────
##[/codeblock]The structure of the data that is received on
## [signal UDPecan.advert_received].
##
## It actually makes it a lot easier to reason about if I specify the advert
## class rather than use a dictionary, because of documentation, and tool-tips.
##[br][br]
## [code]var post:Dictionary = {[/code][br]
## [code]  &'type'   :   0,   # MsgType - the type of packet[/code][br]
## [code]  &'ip'     :  '',   # String - ip address of advertiser[/code][br]
## [code]  &'port'   :   0,   # int - port on advertiser[/code][br]
## [code]  &'ident'  :null,   # Variant - The identity of the sender[/code][br]
## [code]  &'ad_id'  :null,   # Variant - advert unique id[/code][br]
## [code]  &'kind'   :  '',   # StringName - the kind of advertisement[/code][br]
## [code]  &'content':null,   # Variant - Decoded Advertisement Data[/code][br]
## [code]}[/code]
class Msg:
	pass
# NOTE: The above is a hacky way to get an individual page on any subject.

# ██████  ██████   ██████  ██████  ███████ ██████  ████████ ██ ███████ ███████ #
# ██   ██ ██   ██ ██    ██ ██   ██ ██      ██   ██    ██    ██ ██      ██      #
# ██████  ██████  ██    ██ ██████  █████   ██████     ██    ██ █████   ███████ #
# ██      ██   ██ ██    ██ ██      ██      ██   ██    ██    ██ ██           ██ #
# ██      ██   ██  ██████  ██      ███████ ██   ██    ██    ██ ███████ ███████ #
func                        ________PROPERTIES_______              ()->void:pass

static var online_version:Dictionary

## Starts the maintenance timer when the node becomes ready.
@export var start_on_ready:bool = false

## Allow this session to be promoted to the Leader role.
@export var allow_promotion:bool = false

## Time in milliseconds between maintenance timer runs.
@export_custom(PROPERTY_HINT_NONE, "suffix:ms")
var maintenance_interval:int = 6000

## Milliseconds after last seen that a peer or advertisement is considered expired.
@export_custom(PROPERTY_HINT_NONE, "suffix:ms")
var expiration_threshold: int = 9000

@export_group("UDP Packet Peet")
## IP address to bind the UDP socket to. Usually "0.0.0.0" for all interfaces,
## but can be set to "127.0.0.1" for single-host testing.
@export var bind_address: String = "0.0.0.0" :
	set(v):
		bind_address = v
		if is_instance_valid(_udp_packet_peer) \
				and _udp_packet_peer.is_bound():
			stop()

## UDP port the leader should bind to. Peers send heartbeats here.
## [br]This is Necessary for Multi-Seat Hosts where there are more than one
## process running the discovery. This is the primary mechanism that enables
## testing on a single host.
@export_range(1024, 65535) var leader_port: int = 54323


## Local IP
@export_custom(PROPERTY_HINT_NONE, '', PROPERTY_USAGE_READ_ONLY)
var local_port:int

## Local Port
@export_custom(PROPERTY_HINT_NONE, '', PROPERTY_USAGE_READ_ONLY)
var local_ip:String

@export_group('Presence')

## If true, periodically broadcasts basic presence information.
@export var advertise_presence: bool = false

## A Unique ID identifying this host.
@export var local_ident: Variant = null

## Optional custom data attached to presence broadcasts ([Variant]).
@export var custom_presence_content: Variant = null

# A cached reference to the peer presence advertisement.
var _peer_advert_ident:Variant = null

# [================================[ Private ]================================]
# The Timer to trigger maintenance cycles.
var _maintenance_timer:Timer

# The Packet Peer used to to send and receive packets on the network.
var _udp_packet_peer:PacketPeerUDP

# The current destination set to one of [enum Dest]
var _dest:int = Dest.NONE

# Remote Host Information
var _peers:Dictionary = {}

# Leader Information.
var _leader_ident:Variant = null
var _leader_info:Dictionary

# True while a one-shot promotion timer is waiting (leader election jitter).
var _promotion_pending:bool = false

# Advertisments we are sending
var _posted_adverts:Dictionary

# Advertisements we have received
var _received_adverts:Dictionary

# [============================[ Encode / Decode ]============================]
# [Callable] used to serialize advertisement data before sending.
# [br]Default: returns [method @GlobalScope.var_to_bytes](data)
var _encoders:Dictionary[StringName,Callable] = {&'default':_encode_advertisement}

# [Callable] used to deserialize received advertisement data.
# [br]Default: returns [method @GlobalScope.bytes_to_var](bytes) or null on failure
var _decoders:Dictionary[StringName,Callable] = {&'default':_decode_advertisement}

# [==============================[ Generate ID ]==============================]
## Custom [Callable] used to Generate an identity value.
## [br]Signature: f(x:Variant)->Variant
## [br]Default: var_to_bytes(randi()).hex_encode()
var ident_generator: Callable = fruity_name

## Custom [Callable] to format the identity as desired.
## [br]Signature: f(x:Variant)->String
## [br]Default: str(x)
var idstr: Callable = str


#            ███████ ██  ██████  ███    ██  █████  ██      ███████             #
#            ██      ██ ██       ████   ██ ██   ██ ██      ██                  #
#            ███████ ██ ██   ███ ██ ██  ██ ███████ ██      ███████             #
#                 ██ ██ ██    ██ ██  ██ ██ ██   ██ ██           ██             #
#            ███████ ██  ██████  ██   ████ ██   ██ ███████ ███████             #
func                        _________SIGNALS_________              ()->void:pass

#[============================[ Lifetime Signals ]============================]

## Emitted when the [method start] method finishes.
signal started

## Emitted when the UDP socket successfully binds (leader or peer mode).
## leader, local_port, local_ip are now valid
signal bound_to_port(port: int, as_leader: bool)

## Emitted when this instance successfully promotes itself to leader.
signal promoted

## emitted at the start of the stop function before taking action
signal stopping

## emitted at the end of the stop function
signal stopped


#[=========================[ Receiving Information ]=========================]

## Emitted when this instance receives the leader information.
signal leader_updated(leader_ident:Variant, msg:Dictionary)

## Emitted when a new peer is detected.
signal peer_appeared(peer_ident:Variant, peer_dict: Dictionary)

## Emitted when an existing peer sends updated information.
signal peer_updated(peer_ident:Variant, peer_dict: Dictionary)

## Emitted when a peer expires or sends explicit shutdown.
signal peer_vanished(peer_ident:Variant)

## Emitted when a new advertisement is received from any peer.
## [br][param msg_ident] = either a user specified variant or [color=khaki]"ip:port"[/color]
## [br][param msg] is a [Dictionary] with the layout specified in [UDPecan.Msg]
signal advert_received(msg_ident:Variant, msg:Dictionary)

## Emitted when an existing advertisement is updated.
signal advert_updated(advert_ident:Variant, msg:Dictionary)

## Emitted when an advertisement expires (timeout).
signal advert_expired(advert_ident:Variant)

## For a individual page with this info: [UDPecan.Post]
signal post_added(post_ident:Variant, kind:StringName, post:Variant)

## Emitted when an existing advertisement is updated.
signal post_updated(post_ident:Variant, kind:StringName, post:Variant)

## Emitted when an advertisement expires (timeout).
signal post_removed(post_ident:Variant)


#             ███████ ██    ██ ███████ ███    ██ ████████ ███████              #
#             ██      ██    ██ ██      ████   ██    ██    ██                   #
#             █████   ██    ██ █████   ██ ██  ██    ██    ███████              #
#             ██       ██  ██  ██      ██  ██ ██    ██         ██              #
#             ███████   ████   ███████ ██   ████    ██    ███████              #
func                        __________EVENTS_________              ()->void:pass

func _on_maintenance_timeout() -> void:
	if not is_instance_valid(_udp_packet_peer):
		print("ERROR: Invalid udp peer")
		return
	if not _udp_packet_peer.is_bound():
		print("ERROR: udp peer is not bound to a port")
		return
	# Restart maintenance interval
	_maintenance_timer.wait_time = maintenance_interval / 1000.0

	# Add or Remove peer advertisement
	if advertise_presence and not _peer_advert_ident:
		_peer_advert_ident = post_advert(
				custom_presence_content, &'peer'
		)
	if not advertise_presence and _peer_advert_ident:
		remove_post(_peer_advert_ident)
		_peer_advert_ident = null

	# Maintain Posted Adverts
	if not _posted_adverts.is_empty(): _broadcast_adverts()
	_remote_advert_maintenance()

	# maintain logistics.
	if not _peers.is_empty(): _peer_list_maintenance()
	if is_leader(): _leader_maintenance()
	else: _peer_maintenance()


#      ██████  ██    ██ ███████ ██████  ██████  ██ ██████  ███████ ███████     #
#     ██    ██ ██    ██ ██      ██   ██ ██   ██ ██ ██   ██ ██      ██          #
#     ██    ██ ██    ██ █████   ██████  ██████  ██ ██   ██ █████   ███████     #
#     ██    ██  ██  ██  ██      ██   ██ ██   ██ ██ ██   ██ ██           ██     #
#      ██████    ████   ███████ ██   ██ ██   ██ ██ ██████  ███████ ███████     #
func                        ________OVERRIDES________              ()->void:pass

static func _static_init() -> void:
	if VERSION_CHECK_ENABLED and online_version.is_empty():
		version_check()


func _init() -> void:
	if Engine.is_editor_hint():
		process_mode = Node.PROCESS_MODE_DISABLED
		return
	name = &"UDPecan"

	# Maintenance Timers
	_maintenance_timer = Timer.new()
	_maintenance_timer.name = "MaintenanceTimer"
	add_child(_maintenance_timer, true)
	if _maintenance_timer.timeout.connect(_on_maintenance_timeout) != OK:
		print("ERROR: connection to maintenance timer failed")


func _ready() -> void:
	if start_on_ready: start()


# If the [member _udp_packet_peer] is bound, we call [method _process_udp_listener]
func _process(_delta:float) -> void:
	if _udp_packet_peer and _udp_packet_peer.is_bound():
		_process_udp_listener()


#         ███    ███ ███████ ████████ ██   ██  ██████  ██████  ███████         #
#         ████  ████ ██         ██    ██   ██ ██    ██ ██   ██ ██              #
#         ██ ████ ██ █████      ██    ███████ ██    ██ ██   ██ ███████         #
#         ██  ██  ██ ██         ██    ██   ██ ██    ██ ██   ██      ██         #
#         ██      ██ ███████    ██    ██   ██  ██████  ██████  ███████         #
func                        _________METHODS_________              ()->void:pass

## Starts the UDP listener and maintenance timer.
## Attempts to bind as leader first; falls back to peer mode if port is taken.
func start() -> void:
	# At the top of _ready or start_listener
	if IP.get_local_addresses().is_empty():
		print("ERROR: There are no ip addresses, Check Network Settings")
		return

	# Prefer concrete bind_address; else best LAN IPv4 (not first interface blindly).
	local_ip = _resolve_local_ip()

	if local_ident == null:
		local_ident = ident_generator.call()

	if allow_promotion:
		_bind_as_leader()

	if not is_leader(): # Binding as leader failed.
		_bind_as_peer()

	_maintenance_timer.start(maintenance_interval / 1000.0)
	started.emit()


## Stops listening, closes the UDP socket, stops the timer and clears state.
## Sends a shutdown announcement before closing.
func stop() -> void:
	stopping.emit()
	if not _maintenance_timer.is_stopped():
		_maintenance_timer.stop()
		if advertise_presence: _announce_stop()

	_leader_ident = null
	_leader_info.clear()
	_promotion_pending = false
	_dest = Dest.NONE

	close_udp_packet_peer()
	stopped.emit()


## returns true if this instance is currently acting as leader (read-only after binding).
func is_leader() -> bool:
	return local_port == leader_port


## Utility function to test a timestamp and threshold against the current time
func is_expired( time:int ) -> bool:
	return time + expiration_threshold < Time.get_ticks_msec()


## Gets a random port number in the Dynamic, private or ephemeral ports range
## [49152,65535]
func get_random_port_number() -> int:
	return randi() % (65535-49152) + 49152


# --- Advertisement Encoding / Decoding abstraction ---
func assign_encoding(kind:StringName, encoder:Callable, decoder:Callable) -> void:
	_encoders[kind] = encoder
	_decoders[kind] = decoder


func udp_report() -> String:
	if not is_instance_valid(_udp_packet_peer):
		return "_udp_packet_peer:PacketPeerUDP is not valid"
	var udp := _udp_packet_peer
	return "_udp_packet_peer:" +  '\n'.join([
		["Report", ""],
		["encode_buffer_max_size[default: 8388608]", udp.encode_buffer_max_size],
		["get_local_port", udp.get_local_port() ],
		["is_bound", udp.is_bound()],
		["is_socket_connected", udp.is_socket_connected()],
		["available_packet_count", udp.get_available_packet_count()],
		["- Last Received -", ""],
		["get_packet_error", udp.get_packet_error()],
		["get_packet_ip", udp.get_packet_ip()],
		["get_packet_port", udp.get_packet_port()],
		].map(func(r:Array)->String:return "%s: %s" % r))

#       ██    ██ ██████  ██████        ██████  ███████ ███████ ██████          #
#       ██    ██ ██   ██ ██   ██       ██   ██ ██      ██      ██   ██         #
#       ██    ██ ██   ██ ██████  █████ ██████  █████   █████   ██████          #
#       ██    ██ ██   ██ ██            ██      ██      ██      ██   ██         #
#        ██████  ██████  ██            ██      ███████ ███████ ██   ██         #
func                      _____UDP_PACKET_PEER_____                ()->void:pass

## Close any previously active listener.
func close_udp_packet_peer() -> void:
	if is_instance_valid(_udp_packet_peer) \
			and _udp_packet_peer.is_bound():
		print("INFO: Closing out old listener bound to",
				_udp_packet_peer.get_local_port())
		_udp_packet_peer.close()
		_udp_packet_peer = null
	_dest = Dest.NONE
	local_port = -1
	local_ip = '-'


# True for wildcard / empty bind hosts that are not valid peer destinations.
func _is_wildcard_bind(address:String) -> bool:
	return address.is_empty() \
			or address == "0.0.0.0" \
			or address == "::" \
			or address == "-"


func _is_ipv4_address(address:String) -> bool:
	return address.count(".") == 3 and not address.contains(":")


func _is_loopback_ip(address:String) -> bool:
	return address.begins_with("127.") or address == "::1"


func _is_link_local_ip(address:String) -> bool:
	return address.begins_with("169.254.") or address.begins_with("fe80:")


func _is_private_ipv4(address:String) -> bool:
	if address.begins_with("10.") or address.begins_with("192.168."):
		return true
	if address.begins_with("172."):
		var parts:PackedStringArray = address.split(".")
		if parts.size() >= 2:
			var second:int = int(parts[1])
			return second >= 16 and second <= 31
	return false


# Penalize virtual / tunnel adapters so Docker/VPN/WSL lose to real LAN NICs.
func _interface_name_penalty(if_name:String, friendly:String) -> int:
	var label:String = (if_name + " " + friendly).to_lower()
	var penalty:int = 0
	const BAD:PackedStringArray = [
		"docker", "veth", "br-", "vmnet", "vbox", "virtual", "wsl",
		"hyper-v", "hyperv", "tun", "tap", "wg", "vpn", "zerotier",
		"hamachi", "tailscale", "utun", "loopback", "isatap", "teredo",
		"bluetooth", "npcap", "meta",
	]
	for token:String in BAD:
		if label.contains(token):
			penalty += 100
	# Mild preference for wired over wireless when both are private LAN.
	if label.contains("wi-fi") or label.contains("wifi") \
			or label.contains("wlan") or label.contains("wireless"):
		penalty += 10
	return penalty


# Higher is better; negative means reject. IPv4 LAN discovery only.
func _score_local_ip(address:String, if_name:String = "", friendly:String = "") -> int:
	if _is_wildcard_bind(address) or _is_loopback_ip(address):
		return -1
	if not _is_ipv4_address(address):
		return -1
	if _is_link_local_ip(address):
		return -1
	var score:int = 20
	if _is_private_ipv4(address):
		score += 50
	score -= _interface_name_penalty(if_name, friendly)
	return score


# Choose a LAN-facing IPv4 from [method IP.get_local_interfaces], not [code][0][/code].
func _pick_best_local_ip() -> String:
	var best_ip:String = ""
	var best_score:int = -1
	for iface:Variant in IP.get_local_interfaces():
		if not (iface is Dictionary):
			continue
		var d:Dictionary = iface
		var if_name:String = str(d.get("name", ""))
		var friendly:String = str(d.get("friendly", ""))
		var addresses:Variant = d.get("addresses", [])
		if not (addresses is Array) and not (addresses is PackedStringArray):
			continue
		for address:Variant in addresses:
			var ip:String = str(address)
			var s:int = _score_local_ip(ip, if_name, friendly)
			if s > best_score:
				best_score = s
				best_ip = ip
	if not best_ip.is_empty():
		return best_ip
	for address:String in IP.get_local_addresses():
		if _score_local_ip(address) >= 0:
			return address
	var addrs:PackedStringArray = IP.get_local_addresses()
	if not addrs.is_empty():
		return addrs[0]
	return "127.0.0.1"


# Routable IP peers should use. Prefer a concrete [member bind_address], else a
# previously chosen preferred address, else the best-scoring LAN interface.
func _resolve_local_ip(preferred:String = "") -> String:
	if not _is_wildcard_bind(bind_address):
		return bind_address
	# Keep a prior good choice across rebinds (demote / re-promote).
	if not _is_wildcard_bind(preferred) and _score_local_ip(preferred) >= 0:
		return preferred
	if not _is_wildcard_bind(local_ip) and _score_local_ip(local_ip) >= 0:
		return local_ip
	return _pick_best_local_ip()


## Setter Function with side effects.
func set_udp_packet_peer( new_packet_peer:PacketPeerUDP ) -> void:
	if not is_instance_valid(new_packet_peer):
		print("WARNING: Refusing to set udp_listener to null,",
				"You might want to use stop() instead.")
		return

	# close_udp_packet_peer() clears local_ip; keep a candidate for resolve.
	var preferred_ip:String = local_ip

	if is_instance_valid(_udp_packet_peer) \
			and _udp_packet_peer.is_bound():
		close_udp_packet_peer()

	_udp_packet_peer = new_packet_peer
	local_port = _udp_packet_peer.get_local_port()
	# Never advertise 0.0.0.0 / :: as a destination — peers cannot send there.
	local_ip = _resolve_local_ip(preferred_ip)

	print("DEBUG: Bound as", "Leader" if is_leader() else "Peer",
			"to %s:%s" % [local_ip, local_port])
	bound_to_port.emit( local_port, is_leader() )


# Bind to the leader port
func _bind_as_leader() -> void:
	var udp_peer := PacketPeerUDP.new()
	udp_peer.set_broadcast_enabled(true)

	var err:Error = udp_peer.bind(leader_port, bind_address)
	match err:
		OK:
			set_udp_packet_peer(udp_peer)
			_leader_ident = local_ident
			_leader_info[&'port'] = leader_port
			_leader_info[&'ip'] = local_ip
			_leader_info[&'last_seen'] = Time.get_ticks_msec()
			_promotion_pending = false
			promoted.emit()
			# Tell peers immediately — do not wait for the next maintenance tick.
			_announce_leader_presence()
		ERR_UNAVAILABLE: # Another process on this host already holds the port.
			pass
		_:
			print("ERROR: Binding as leader to", leader_port,
					"failed with error string:",err, error_string(err))


# Keep trying to bind to ports until we get one
func _bind_as_peer() -> void:
	var udp_peer := PacketPeerUDP.new()
	udp_peer.set_broadcast_enabled(true)
	var attempt:int = 0
	var max_attempts:int = 100

	while attempt < max_attempts:
		attempt += 1
		var random_port:int = get_random_port_number()
		if udp_peer.bind(random_port, bind_address) == OK:
			set_udp_packet_peer(udp_peer)
			return
		print("ERROR: Failed to bind", bind_address, ":", random_port)
	_maintenance_timer.start(maintenance_interval << 1)


# Parse dotted IPv4 into four octets, or empty on failure.
func _parse_ipv4_octets(address:String) -> PackedInt32Array:
	if not _is_ipv4_address(address):
		return PackedInt32Array()
	var parts:PackedStringArray = address.split(".")
	if parts.size() != 4:
		return PackedInt32Array()
	var out:Array = []
	for part:String in parts:
		if not part.is_valid_int():
			return PackedInt32Array()
		var n:int = int(part)
		if n < 0 or n > 255:
			return PackedInt32Array()
		out.append(n)
	return out


func _ipv4_octets_to_u32(octets:PackedInt32Array) -> int:
	return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]


func _u32_to_ipv4(value:int) -> String:
	return "%d.%d.%d.%d" % [
		(value >> 24) & 0xff,
		(value >> 16) & 0xff,
		(value >> 8) & 0xff,
		value & 0xff,
	]


# Best-effort prefix without OS netmask data (typical home/office LANs).
func _guess_ipv4_prefix_length(_ip:String) -> int:
	# Godot does not expose interface netmasks; /24 matches most discovery LANs.
	return 24


# Subnet-directed broadcast for [param ip], or empty string if not computable.
func _subnet_broadcast_for(ip:String) -> String:
	var octets:PackedInt32Array = _parse_ipv4_octets(ip)
	if octets.is_empty():
		return ""
	if _is_loopback_ip(ip) or _is_link_local_ip(ip):
		return ""
	var prefix:int = clampi(_guess_ipv4_prefix_length(ip), 1, 30)
	var host_bits:int = 32 - prefix
	var mask:int = (0xffffffff << host_bits) & 0xffffffff
	var network:int = _ipv4_octets_to_u32(octets) & mask
	var broadcast:int = network | (~mask & 0xffffffff)
	return _u32_to_ipv4(broadcast)


# Destination used for discovery broadcasts.
# Prefers subnet broadcast (works when limited broadcast is filtered); falls
# back to 255.255.255.255; loopback bind uses 127.0.0.1 for single-host tests.
func _resolve_broadcast_address() -> String:
	if bind_address.begins_with("127.") or _is_loopback_ip(local_ip):
		return "127.0.0.1"
	var subnet:String = _subnet_broadcast_for(local_ip)
	if not subnet.is_empty():
		return subnet
	return "255.255.255.255"


func set_broadcast_destination() -> Error:
	if not is_instance_valid(_udp_packet_peer):
		print("ERROR: Cannot set_dest_address on invalid udp_listener")
		return ERR_UNAVAILABLE

	_dest = Dest.BROADCAST
	var dest_address:String = _resolve_broadcast_address()
	var dest_port:int = leader_port

	var err:Error = _udp_packet_peer.set_dest_address(dest_address, dest_port)
	if err:
		# Some stacks reject subnet broadcast; retry limited broadcast.
		if dest_address != "255.255.255.255" and dest_address != "127.0.0.1":
			err = _udp_packet_peer.set_dest_address("255.255.255.255", dest_port)
		if err:
			_dest = Dest.ERROR
			print("ERROR: ", error_string(err))

	return err


func set_leader_destination() -> Error:
	if not is_instance_valid(_udp_packet_peer):
		print("ERROR: Cannot set_dest_address on invalid udp_listener")
		return ERR_UNAVAILABLE

	var dest_address:String = _leader_info.get(&'ip')
	var dest_port:int = _leader_info.get(&'port')
	_dest = Dest.LEADER

	var err:Error = _udp_packet_peer.set_dest_address(dest_address, dest_port)
	if err:
		_dest = Dest.ERROR
		print("ERROR: ", error_string(err))
	return err

#                   ██████  ███████ ███████ ██████  ███████                    #
#                   ██   ██ ██      ██      ██   ██ ██                         #
#                   ██████  █████   █████   ██████  ███████                    #
#                   ██      ██      ██      ██   ██      ██                    #
#                   ██      ███████ ███████ ██   ██ ███████                    #
func                        __________PEERS__________              ()->void:pass

func clear_leader_info() -> void:
	_leader_ident = null
	_leader_info.clear()


func update_leader_info( leader_ident:Variant, msg:Dictionary ) -> void:
	_leader_ident = leader_ident
	_leader_info.merge(msg, true)
	# In-flight promotion timer is left armed; _on_promotion_timer no-ops if
	# _leader_ident is set (avoids double timers by keeping _promotion_pending).


# Deterministic 0 .. maintenance_interval/2 ms from local identity.
func _promotion_jitter_ms() -> int:
	var span:int = maxi(1, maintenance_interval >> 1)
	return absi(hash(idstr.call(local_ident))) % span


# Schedule a delayed leader bind so peers do not all race on the same tick.
func _schedule_promotion_attempt() -> void:
	if _promotion_pending or not allow_promotion:
		return
	if is_leader() or _leader_ident != null:
		return
	if not is_inside_tree():
		return
	_promotion_pending = true
	var delay_s:float = _promotion_jitter_ms() / 1000.0
	@warning_ignore("return_value_discarded")
	get_tree().create_timer(delay_s).timeout.connect(
			_on_promotion_timer, CONNECT_ONE_SHOT)


func _on_promotion_timer() -> void:
	_promotion_pending = false
	if not allow_promotion or is_leader() or _leader_ident != null:
		return
	if not is_instance_valid(_udp_packet_peer) or not _udp_packet_peer.is_bound():
		return
	_bind_as_leader()
	if is_leader():
		return
	# Lost the race: broadcast heartbeat so the winner learns about us quickly.
	_dest = Dest.NONE
	_peer_heartbeat()


func _build_leader_presence_packet() -> Dictionary:
	var packet: Dictionary = {
		&"type": MsgType.PEER | MsgType.LEADER | (MsgType.ADVERT if advertise_presence else 0),
		&'ident': local_ident,
		&'ip': local_ip,
		&'port': leader_port,
	}
	if advertise_presence and custom_presence_content:
		packet[&'data'] = custom_presence_content
	return packet


# Immediate LAN announcement after promotion (do not wait for maintenance).
func _announce_leader_presence() -> void:
	if not is_instance_valid(_udp_packet_peer) or not _udp_packet_peer.is_bound():
		return
	var bytes:PackedByteArray = var_to_bytes(_build_leader_presence_packet())
	var err:Error = set_broadcast_destination()
	if err != OK:
		print("ERROR: leader announce set_dest failed:", error_string(err))
		return
	err = _udp_packet_peer.put_packet(bytes)
	if err != OK:
		print("ERROR: leader announce put_packet failed:", error_string(err))


# Deterministic dual-leader rule: the lexicographically smaller id string wins.
# Used so two self-claimed leaders on different hosts converge instead of split-brain.
func _should_yield_to_leader(other_ident:Variant) -> bool:
	return idstr.call(other_ident) < idstr.call(local_ident)


# Drop the leader socket, rebind as peer, and follow [param new_leader_ident].
func _demote_to_peer(new_leader_ident:Variant, msg:Dictionary) -> void:
	print("INFO: Yielding leadership to", idstr.call(new_leader_ident))
	close_udp_packet_peer()
	_dest = Dest.NONE
	_bind_as_peer()
	if not is_instance_valid(_udp_packet_peer) or not _udp_packet_peer.is_bound():
		print("ERROR: demote rebind as peer failed")
		return
	update_leader_info(new_leader_ident, msg)
	leader_updated.emit(_leader_ident, _leader_info)


func add_peer( peer_ident:Variant, msg:Dictionary ) -> void:
	_peers[peer_ident] = msg
	peer_appeared.emit( peer_ident, msg )


func remove_peer(peer_ident:Variant) -> void:
	if _peers.has(peer_ident):
		if not _peers.erase( peer_ident ):
			print("ERROR: peer_ident did not exist in _peers")
		peer_vanished.emit( peer_ident )
	else:
		# FIXME: peer_ident not found in peers
		pass


#                      ██████   ██████  ███████ ████████                       #
#                      ██   ██ ██    ██ ██         ██                          #
#                      ██████  ██    ██ ███████    ██                          #
#                      ██      ██    ██      ██    ██                          #
#                      ██       ██████  ███████    ██                          #
func                        __________POST___________              ()->void:pass


#  _  _
# | \| |_____ __ __
# | .` / -_) V  V /
# |_|\_\___|\_/\_/
# New

#    _      _    _
#   /_\  __| |__| |
#  / _ \/ _` / _` |
# /_/ \_\__,_\__,_|
# Add

## Manually set or update an advertisement this instance should broadcast.
func post_advert(
		content:Variant,
		kind:StringName = StringName(),
		ad_id:Variant = ident_generator.call()) -> Variant:

	var new_post:bool = not _posted_adverts.has(ad_id)

	if _encoders.has(kind):
		content = _encoders[kind].call(content)

	_posted_adverts[ad_id] = { &'kind': kind, &'content': content }

	if new_post: post_added.emit( ad_id, kind, content )
	else: post_updated.emit( ad_id, kind, content )
	return ad_id

#  _  _
# | || |__ _ ___
# | __ / _` (_-<
# |_||_\__,_/__/
# Has

func has_post(ad_id:Variant) -> bool:
	return _posted_adverts.has(ad_id)

#   ___     _
#  / __|___| |_
# | (_ / -_)  _|
#  \___\___|\__|
# Get

func get_post( ad_id:Variant ) -> Variant:
	var pair:Dictionary = _posted_adverts.get(ad_id)
	# TODO use decoder to get back information.
	return pair.content


func get_posts() -> Dictionary:
	return _posted_adverts.duplicate()

#  __  __         _
# |  \/  |___  __| |
# | |\/| / _ \/ _` |
# |_|  |_\___/\__,_|
# Modify

func modify_post( ad_id:Variant, kind:StringName, content:Variant ) -> void:
	var pair:Dictionary = _posted_adverts.get(ad_id)
	pair.kind = kind
	# TODO use encoder to re-encode inforamtion
	pair.content = content

#   ___
#  / __|___ _ __
# | (__/ _ \ '  \
#  \___\___/_|_|_|
# Communicate

#  ___
# | _ \___ _ __
# |   / -_) '  \
# |_|_\___|_|_|_|
# Remove

func remove_post( ad_id:Variant ) -> void:
	if not _posted_adverts.erase(ad_id):
		print("ERROR: missing ad_id")
		return
	post_removed.emit(ad_id)


## Removes all locally published advertisements.
func clear_posts() -> void:
	for ad_id:Variant in _posted_adverts.keys():
		remove_post(ad_id)
	_posted_adverts.clear()


#           █████  ██████  ██    ██ ███████ ██████  ████████ ███████           #
#          ██   ██ ██   ██ ██    ██ ██      ██   ██    ██    ██                #
#          ███████ ██   ██ ██    ██ █████   ██████     ██    ███████           #
#          ██   ██ ██   ██  ██  ██  ██      ██   ██    ██         ██           #
#          ██   ██ ██████    ████   ███████ ██   ██    ██    ███████           #
func                        _________ADVERTS_________              ()->void:pass

func expire_peer_adverts( peer_ident:Variant ) -> void:
	# Expire adverts that originated from the given peer (sender).
	for ad_id:Variant in _received_adverts.keys():
		var msg:Dictionary = _received_adverts[ad_id]
		if peer_ident == msg.get(&'ident'):
			remove_advert(ad_id)

#  _  _
# | \| |_____ __ __
# | .` / -_) V  V /
# |_|\_\___|\_/\_/
# New

#    _      _    _
#   /_\  __| |__| |
#  / _ \/ _` / _` |
# /_/ \_\__,_\__,_|
# Add

#  _  _
# | || |__ _ ___
# | __ / _` (_-<
# |_||_\__,_/__/
# Has

#   ___     _
#  / __|___| |_
# | (_ / -_)  _|
#  \___\___|\__|
# Get

func get_advert( advert_ident:Variant ) -> Dictionary:
	return _received_adverts.get(advert_ident)


func get_adverts() -> Dictionary:
	return _received_adverts.duplicate()

#  __  __         _
# |  \/  |___  __| |
# | |\/| / _ \/ _` |
# |_|  |_\___/\__,_|
# Modify

#   ___
#  / __|___ _ __
# | (__/ _ \ '  \
#  \___\___/_|_|_|
# Communicate

#  ___
# | _ \___ _ __
# |   / -_) '  \
# |_|_\___|_|_|_|
# Remove

func remove_advert(advert_ident:Variant) ->void:
	if not _received_adverts.erase(advert_ident):
		print("ERROR: Failed to remove remote advert:", advert_ident)
	advert_expired.emit(advert_ident)


## Removes all adverts received
func clear_adverts() -> void:
	for ad_id:Variant in _received_adverts.keys():
		remove_advert(ad_id)
	_received_adverts.clear()


#                      ███████ ███████ ███    ██ ██████                        #
#                      ██      ██      ████   ██ ██   ██                       #
#                      ███████ █████   ██ ██  ██ ██   ██                       #
#                           ██ ██      ██  ██ ██ ██   ██                       #
#                      ███████ ███████ ██   ████ ██████                        #
func                        __________SEND___________              ()->void:pass

# (Peer => (broadcast|leader.ip):leader_port)
func _peer_heartbeat() -> void:
	# All packets are sent to the Leader, but only ADVERT packets
	# are propagated to other PEERS.
	# Include ip/port so peer records stay complete across relay / leader handoff
	# even if get_packet_ip() is empty on some platforms.
	var msg: Dictionary = {
		&"type": MsgType.PEER,
		&'ident': local_ident,
		&'ip': local_ip,
		&'port': local_port,
	}

	var bytes := var_to_bytes(msg)
	_send_to_leader(bytes)


# Peer sends one final packet announcing it is leaving.
# Leader will relay it like any other PEER packet.
func _send_to_leader( bytes:PackedByteArray ) -> void:
	var err: Error = OK
	if _dest != Dest.LEADER and _leader_ident != null:
		err = set_leader_destination()
	elif _dest != Dest.BROADCAST:
		err = set_broadcast_destination()
	if err != OK:
		print("ERROR: set_dest_address failed:", error_string(err))
		return

	err = _udp_packet_peer.put_packet(bytes)
	if err != OK:
		print("ERROR: put_packet failed:", error_string(err))
		# FIXME Reset the leader
		stop()


# Broadcast advertisements to all using the leader port[br]
# packet format: {[br]
# [b]  [code]&'type'[/code]: MsgType.ADVERT,[br]
# [b]  [code]&'data'[/code]: encoded[br]
# }[br]
func _broadcast_adverts() -> void:
	var err: Error = OK
	# Use the leader if they exist and we are not them.
	if not is_leader() \
			and _leader_ident != null:
		err = set_leader_destination()
	# else broadcast
	elif _dest != Dest.BROADCAST:
		err = set_broadcast_destination()
	# else failure.
	if err != OK:
		print("ERROR: set_dest_address failed:", error_string(err))
		return

	# keep local advertisements alive
	for ad_id:Variant in _posted_adverts.keys():
		var post:Dictionary = _posted_adverts.get(ad_id)
		var content:Variant = post.get(&'content', post)
		var kind:StringName = post.get(&'kind')

		var msg: Dictionary = {
			&'ident': local_ident,
			&"type": MsgType.ADVERT,
			&'ad_id'  : ad_id,
			&'content': content
		}
		if kind: msg[&'kind'] = kind

		var bytes:PackedByteArray = var_to_bytes(msg)
		if bytes.is_empty():
			print("ERROR: advert bytes is empty")
			continue

		err = _udp_packet_peer.put_packet(bytes)
		if err != OK:
			print("ERROR: put_packet failed:", error_string(err))
			print("ERROR: ", udp_report())
			_dest = Dest.ERROR
			break


# update the packet and send to peers.
func _distribute_packet(source_ip:String, source_port:int, msg:Dictionary) -> void:
	msg[&'type'] = msg.get(&'type', 0) | MsgType.RELAY
	var relay_bytes := var_to_bytes(msg)
	for peer_ident:Variant in _peers:
		var peer_info:Dictionary = _peers[peer_ident]
		if peer_info.is_empty():
			if not _peers.erase(peer_ident):
				pass
				#FIXME: peer_ident in dictionary without info
			continue

		var peer_ip:String = peer_info.get(&'ip', '')
		var peer_port:int = peer_info.get(&'port', 0)

		# Skip sending a peer their own information
		if source_ip == peer_ip \
				and source_port == peer_port:
			continue

		_dest = Dest.PEER
		var err:Error = _udp_packet_peer.set_dest_address(peer_ip, peer_port)
		if err != OK:
			_dest = Dest.ERROR
			print("ERROR: relay set_dest_address failed for", peer_ident, ":", error_string(err))
			continue

		err = _udp_packet_peer.put_packet(relay_bytes)
		if err != OK:
			print("ERROR: relay put_packet failed for", peer_ident, ":", error_string(err))


# Peer sends one final packet announcing it is leaving.
# Leader will relay it like any other PEER packet.
func _announce_stop( reason:String = '') -> void:
	var packet: Dictionary = {
		&"type": MsgType.PEER | MsgType.SHUTDOWN | (MsgType.LEADER if is_leader() else 0),
		&'ident': local_ident,
		&'ip': local_ip,
		&'port': local_port,
		&"content": reason.to_utf8_buffer()
	}

	if is_leader():
		# Relay receivers require origin ip/port on the message body.
		packet[&'port'] = leader_port
		_distribute_packet(local_ip, leader_port, packet)
	else:
		var bytes:PackedByteArray = var_to_bytes(packet)
		_send_to_leader(bytes)


#             ██████  ███████  ██████ ███████ ██ ██    ██ ███████              #
#             ██   ██ ██      ██      ██      ██ ██    ██ ██                   #
#             ██████  █████   ██      █████   ██ ██    ██ █████                #
#             ██   ██ ██      ██      ██      ██  ██  ██  ██                   #
#             ██   ██ ███████  ██████ ███████ ██   ████   ███████              #
func                        _________RECEIVE_________              ()->void:pass

# During the [method _process] cycle, we check the [PacketPeerUDP] for any
# [br]messages waiting for us and process them according to their schema
# [br]
# [br][color=lime_green](2026-02-04)NOTE[/color]: We deliberately use get_packet()
# + bytes_to_var() instead of get_var()
# [br]Reasons:
# [br] - Allows access to raw bytes for logging / debugging / early validation
# [br] - get_packet_ip() and get_packet_port() are only reliable immediately
# [br]   after get_packet() (behavior can be inconsistent after get_var())
# [br] - bytes_to_var() returns null on failure → explicit error path possible
# [br] - Easier to support non-Godot formats later (JSON, custom binary, etc.)
# [br]
# [br]packet format on [method PacketPeer.get_packet]: {
# [br]  [code]type[/code]: [enum MsgType],
# [br]  [code]data[/code]: [PackedByteArray]
# [br]}
# [br]
# Where [code]type[/code] is a bitmask with at least [enum MsgType].ADVERT or [enum MsgType].PEER present
# [br]- ([enum MsgType].PEER | [enum MsgType].ADVERT): Indicates that this peer is visible publicly
# [br]- ([enum MsgType].PEER | [enum MsgType].LEADER): This packet is from the leader
# [br]
# [br]Before distributing to consumers we add 'ip' and 'port'
# [br]And then when we process it ourselves we add 'last_seen'
# [br]Packet format on consumption: {
# [br]  [code]type[/code]     : [enum MsgType],
# [br]  [code]data[/code]     : [PackedByteArray]
# [br]  [code]ip[/code]       : [String] - origin_ip
# [br]  [code]port[/code]     : [int] - origin_port
# [br]  [code]last_seen[/code]: [int] - time_received
# [br]}
func _process_udp_listener() -> void:
	while _udp_packet_peer.get_available_packet_count() > 0:
		var bytes: PackedByteArray = _udp_packet_peer.get_packet()
		var err: Error = _udp_packet_peer.get_packet_error()
		if err != OK:
			print("ERROR: Packet:", error_string(err))
			print("DEFAULT: ", bytes)
			continue
		var time_received:int = Time.get_ticks_msec()
		var sender_ip: String = _udp_packet_peer.get_packet_ip()
		var sender_port: int = _udp_packet_peer.get_packet_port()

		var variant: Variant = bytes_to_var(bytes)
		if not (variant is Dictionary):
			print("ERROR: Deserialization to Dictionary failed")
			continue

		# expected minimum msg format on receipt {
		# 	&"type": MsgType,
		# }
		var msg: Dictionary = variant
		if is_msg_missing_keys(msg, [&'type']):
			print("ERROR: msg is missing keys")
			continue

		var msg_type:int = msg.get(&'type')

		if msg_type & MsgType.RELAY \
				and is_leader():
			print("ERROR: leader should not receive relayed messages")
			continue

		var source_ip:String = ''
		var source_port:int = 0
		# If this is a new message, assign the source details
		# and relay to peers if necessary.
		if not (msg_type & MsgType.RELAY):
			# UDP header is preferred for the return path; body ip/port
			# (from heartbeats) fills in when the header is unavailable.
			source_ip = sender_ip
			source_port = sender_port
			if source_ip.is_empty():
				source_ip = str(msg.get(&'ip', ''))
			if source_port == 0:
				source_port = msg.get(&'port', 0)
			msg[&"ip"] = source_ip
			msg[&"port"] = source_port

			# Relay the appropriate packets onward.
			if msg_type & (MsgType.ADVERT|MsgType.SHUTDOWN) \
					and is_leader():
				_distribute_packet(source_ip, source_port, msg)

		# This message was relayed to us from the leader, fetch the original
		# source ip and port.
		else:
			# get the original ip and port from the msg.
			if is_msg_missing_keys(msg, [&'ip', &'port']):
				print("ERROR: Relay Packet is missing keys: ip, port")
				print("ERROR: Relay Packet:", JSON.stringify(msg))
				continue
			# replace the source_ip and source_port with the relayed values
			source_ip = msg.get(&'ip')
			source_port = msg.get(&'port')

		# Now we can process the message ourselves
		msg[&"last_seen"] = time_received

		# 'source' is the originating host identity.
		var source_ident:Variant = msg.get(&'ident', "%s:%d" % [source_ip, source_port])

		if msg_type & MsgType.PEER:
			_process_peer_packet( source_ident, msg )

		if msg_type & MsgType.ADVERT:
			# All adverts are broadcast by the leader, Skip our own.
			if source_ident == local_ident:
				continue
			# 'ad_id' is the advert's own unique identifier; fall back to
			# source_ident if the msg didn't supply one.
			var ad_id:Variant = msg.get(&'ad_id', source_ident)
			_process_advert_packet( ad_id, msg )


func _process_peer_packet( peer_ident:Variant, msg:Dictionary ) -> void:
	var msg_type:int = msg.get(&'type')

	if msg_type & MsgType.LEADER:
		_process_leader_packet( peer_ident, msg)

	if msg_type & MsgType.SHUTDOWN:
		expire_peer_adverts( peer_ident )
		remove_peer( peer_ident )
		return

	# Update existing entry
	if _peers.has(peer_ident):
		var peer_info:Dictionary = _peers.get(peer_ident)
		peer_info.merge(msg, true)
		peer_updated.emit( peer_ident, msg )
	# Add a new entry
	else:
		add_peer( peer_ident, msg )


func _process_leader_packet( peer_ident:Variant, msg:Dictionary ) -> void:
	var msg_type:int = msg.get(&'type')

	if msg_type & MsgType.SHUTDOWN:
		clear_leader_info()
		_dest = Dest.NONE
		# Jittered election — avoid every peer binding on the same packet.
		_schedule_promotion_attempt()
		return

	# Ignore our own broadcast loopback if the OS delivers it.
	if peer_ident == local_ident:
		return

	# Dual-leader / returning-old-leader: only one identity may keep the role.
	if is_leader():
		if _should_yield_to_leader(peer_ident):
			_demote_to_peer(peer_ident, msg)
		# else keep leadership; the other side should yield when it hears us
		return

	# leader is the same as before
	if _leader_ident == peer_ident:
		update_leader_info(peer_ident, msg)
		return

	# we have a new leader
	update_leader_info(peer_ident, msg)
	leader_updated.emit( _leader_ident, _leader_info )



func _process_advert_packet( ad_id:Variant, msg:Dictionary ) -> void:
	if msg.has(&'kind'):
		var kind:StringName = msg[&'kind']
		if _decoders.has(kind):
			msg[&'decoded'] = _decoders[kind].call(msg)

	if _received_adverts.has(ad_id):
		var old:Dictionary = _received_adverts.get(ad_id)
		# Compare before merge: merge would make old match msg on shared keys.
		var content_changed:bool = compare(old, msg)
		old.merge(msg, true)
		if content_changed:
			advert_updated.emit(ad_id, msg)
	else:
		_received_adverts[ad_id] = msg
		advert_received.emit(ad_id, msg)


#         ██    ██  █████  ██      ██ ██████   █████  ████████ ███████         #
#         ██    ██ ██   ██ ██      ██ ██   ██ ██   ██    ██    ██              #
#         ██    ██ ███████ ██      ██ ██   ██ ███████    ██    █████           #
#          ██  ██  ██   ██ ██      ██ ██   ██ ██   ██    ██    ██              #
#           ████   ██   ██ ███████ ██ ██████  ██   ██    ██    ███████         #
func                        ________VALIDATE_________              ()->void:pass

## Returns the filtered list of [param v] which dont appear as keys in [param d][br]
## NOTE: a simpler call would be to use the dict.has_all(Array) function.
## but then I lose reporting.
static func missing_keys(d:Dictionary, v:Array) -> Array:
	var remaining:Array = v.filter(
			func( k:Variant ) -> bool:
				return not d.has(k))
	return remaining


## msg must contain the listed keys
func is_msg_missing_keys( msg:Dictionary, keys:Array ) -> bool:
	return missing_keys(msg, keys).reduce(
			func(k:Variant, _a:Variant) -> Variant:
				print("DEBUG: msg.has(%s) == false" % [k] )
				return true) != null


## True when advertisement payload differs (ignores [code]last_seen[/code] and [code]type[/code]).
## Used so [signal advert_updated] fires on real content changes, not heartbeat refresh.
func compare(a:Dictionary, b:Dictionary) -> bool:
	# last_seen always advances; type may gain RELAY after leader distribution.
	const IGNORE:Array[StringName] = [&'last_seen', &'type']
	for key:Variant in b:
		if key in IGNORE:
			continue
		if not a.has(key) or a[key] != b[key]:
			return true
	for key:Variant in a:
		if key in IGNORE:
			continue
		if not b.has(key):
			return true
	return false

#        ███    ███  █████  ██ ███    ██ ████████  █████  ██ ███    ██         #
#        ████  ████ ██   ██ ██ ████   ██    ██    ██   ██ ██ ████   ██         #
#        ██ ████ ██ ███████ ██ ██ ██  ██    ██    ███████ ██ ██ ██  ██         #
#        ██  ██  ██ ██   ██ ██ ██  ██ ██    ██    ██   ██ ██ ██  ██ ██         #
#        ██      ██ ██   ██ ██ ██   ████    ██    ██   ██ ██ ██   ████         #
func                        ________MAINTAIN_________              ()->void:pass

# The leader needs to retire expired _peers from its peer list, and maintain its
# heartbeat
func _leader_maintenance() -> void:
	var bytes:PackedByteArray = var_to_bytes(_build_leader_presence_packet())

	# Broadcast so peers and rival leaders hear us (multi-host bind is not exclusive).
	var err:Error = set_broadcast_destination()
	if err == OK:
		err = _udp_packet_peer.put_packet(bytes)
		if err != OK:
			print("ERROR: leader broadcast put_packet failed:", error_string(err))
	else:
		print("ERROR: leader broadcast set_dest failed:", error_string(err))

	if _peers.is_empty():
		return

	for peer_ident:StringName in _peers.keys():
		var peer_info:Dictionary = _peers[peer_ident]

		# Set the destination to the peer
		_dest = Dest.PEER
		var peer_ip:String = peer_info.get(&'ip')
		var peer_port:int = peer_info.get(&'port')
		err = _udp_packet_peer.set_dest_address(peer_ip, peer_port)
		if err != OK:
			_dest = Dest.ERROR
			print("ERROR: set_dest_address failed:", error_string(err))
			continue

		# Send the presence packet.
		err = _udp_packet_peer.put_packet(bytes)
		if err != OK:
			print("ERROR: put_packet failed:", error_string(err))


# The peer needs to attempt to bind to the leader port if the leader becomes
# unresponsive and maintain it's heartbeat
func _peer_maintenance() -> void:
	# Check the leader's last seen, and delete it if expired.
	if not _leader_info.is_empty():
		var last_seen:int = _leader_info.get(&'last_seen')
		if is_expired(last_seen):
			# Leader info has expired — jittered re-election, not a stampede.
			_leader_info.clear()
			_leader_ident = null
			_dest = Dest.NONE
			_schedule_promotion_attempt()
	elif _leader_ident == null and allow_promotion and not _promotion_pending:
		# Never saw a leader (or lost state): keep trying with jitter.
		_schedule_promotion_attempt()

	# If a peer wants packets relayed to it, it needs to notify the leader that
	# it exists.
	_peer_heartbeat()


# The leader needs to retire expired _peers from its peer list, and maintain its
# heartbeat
func _peer_list_maintenance() -> void:
	for peer_ident:StringName in _peers.keys():
		var peer_info:Dictionary = _peers.get(peer_ident)
		var last_seen:int = peer_info.get(&'last_seen', 0)
		# The leader needs to cleanout the peer list if it hasnt seen a peer for a while
		if is_expired(last_seen): remove_peer(peer_ident)


func _remote_advert_maintenance() -> void:
	for ad_id:Variant in _received_adverts.keys():
		var entry: Dictionary = _received_adverts[ad_id]
		var last_seen:int = entry[&"last_seen"]
		if is_expired( last_seen ):
			remove_advert(ad_id)


#       ███████ ███    ██  ██████  ██████  ██████  ██ ███    ██  ██████        #
#       ██      ████   ██ ██      ██    ██ ██   ██ ██ ████   ██ ██             #
#       █████   ██ ██  ██ ██      ██    ██ ██   ██ ██ ██ ██  ██ ██   ███       #
#       ██      ██  ██ ██ ██      ██    ██ ██   ██ ██ ██  ██ ██ ██    ██       #
#       ███████ ██   ████  ██████  ██████  ██████  ██ ██   ████  ██████        #
func                        ________ENCODING_________              ()->void:pass
# Advertisement Encoding / Decoding abstraction

# Default implementation uses Dictionary + var_to_bytes.
# Override these in a subclass for FlatBuffers, JSON, etc.
func _encode_advertisement(variant:Variant) -> PackedByteArray:
	return var_to_bytes(variant)


# Default implementation uses Dictionary + var_to_bytes.
# Override these in a subclass for FlatBuffers, JSON, etc.
func _decode_advertisement(bytes:PackedByteArray) -> Variant:
	var variant:Variant = bytes_to_var(bytes)
	if typeof(variant) == TYPE_NIL:
		print("ERROR: Advertisement decode failed")
		return null
	return variant


#                    ██ ██████  ███████ ███    ██ ████████                     #
#                    ██ ██   ██ ██      ████   ██    ██                        #
#                    ██ ██   ██ █████   ██ ██  ██    ██                        #
#                    ██ ██   ██ ██      ██  ██ ██    ██                        #
#                    ██ ██████  ███████ ██   ████    ██                        #
func                        __________IDENT__________              ()->void:pass

const ADJECTIVES: PackedStringArray = [
	&"Ancient", &"Bold", &"Brave", &"Bright", &"Calm", &"Charming", &"Clever",
	&"Cool", &"Cosmic", &"Crispy", &"Curious", &"Dapper", &"Dazzling", &"Eager",
	&"Electric", &"Elegant", &"Fancy", &"Fearless", &"Fierce", &"Fluffy",
	&"Friendly", &"Funky", &"Fuzzy", &"Gentle", &"Glowing", &"Golden", &"Happy",
	&"Hidden", &"Honest", &"Humble", &"Icy", &"Jolly", &"Juicy", &"Kind",
	&"Lazy", &"Lively", &"Lucky", &"Magic", &"Mellow", &"Merry", &"Mighty",
	&"Mystic", &"Noble", &"Polite", &"Proud", &"Quick", &"Quiet", &"Royal",
	&"Salty", &"Sassy", &"Shiny", &"Silent", &"Silly", &"Silky", &"Sleepy",
	&"Smart", &"Smooth", &"Sneaky", &"Snowy", &"Soft", &"Sour", &"Spicy",
	&"Spry", &"Starry", &"Sturdy", &"Sunny", &"Swift", &"Tame", &"Tangy",
	&"Tasty", &"Thirsty", &"Tidy", &"Tiny", &"Tough", &"Trusty", &"Vivid",
	&"Warm", &"Wild", &"Wise", &"Witty", &"Zesty",
	]

const FRUITS: PackedStringArray = [
	&"Apple", &"Apricot", &"Avocado", &"Banana", &"Blackberry", &"Blueberry",
	&"Cherry", &"Coconut", &"Cranberry", &"Currant", &"Date", &"Dragonfruit",
	&"Durian", &"Elderberry", &"Fig", &"Gooseberry", &"Grape", &"Grapefruit",
	&"Guava", &"Jackfruit", &"Kiwi", &"Kumquat", &"Lemon", &"Lime", &"Lychee",
	&"Mango", &"Melon", &"Mulberry", &"Nectarine", &"Olive", &"Orange",
	&"Papaya", &"Passionfruit", &"Peach", &"Pear", &"Persimmon", &"Pineapple",
	&"Plum", &"Pomegranate", &"Quince", &"Raspberry", &"Starfruit",
	&"Strawberry", &"Tamarind", &"Tangerine", &"Watermelon",
	]

## Generates friendly random device/user names in the style of LocalSend.
## Names are produced as "AdjectiveFruit" pairs (e.g. "SpicyMango").
## Pass a non-negative [param name_seed] for deterministic output (debugging).
static func fruity_name(name_seed:int = -1) -> String:
	if ADJECTIVES.is_empty() or FRUITS.is_empty():
		return "UnknownNut-%d" % [Time.get_ticks_msec() if name_seed < 0 else name_seed]
	var rng := RandomNumberGenerator.new()
	if name_seed >= 0:
		rng.seed = name_seed as int
	else:
		rng.randomize()
	var adj:String = ADJECTIVES[rng.randi() % ADJECTIVES.size()]
	var fruit:String = FRUITS[rng.randi() % FRUITS.size()]
	return "%s%s" % [adj, fruit]


#              ██    ██ ██████  ██████   █████  ████████ ███████               #
#              ██    ██ ██   ██ ██   ██ ██   ██    ██    ██                    #
#              ██    ██ ██████  ██   ██ ███████    ██    █████                 #
#              ██    ██ ██      ██   ██ ██   ██    ██    ██                    #
#               ██████  ██      ██████  ██   ██    ██    ███████               #
func                        __________UPDATE_________              ()->void:pass

static func version_check() -> void:
	if not Engine.is_editor_hint(): return
	var h := HTTPRequest.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(h)
	if h.request(U) != OK: print_rich("UDPecan Version Check HTTPRequest Error")
	var r:Array = await h.request_completed
	h.queue_free()
	if r[1] != 200:
		print("UDPecan Version Check HTTP.response:", r[1])
		return
	var body:PackedByteArray = r[3]
	online_version = JSON.parse_string(body.get_string_from_utf8())
	if online_version and online_version.get("version", "") != V:
		print_rich("[color=yellow][url=%s]UDPecan Update available: %s → %s[/url][/color]" % [S, V, online_version.version])
