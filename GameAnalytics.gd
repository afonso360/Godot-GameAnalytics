extends Node
# GameAnalytics <https://gameanalytics.com/> native GDScript REST API implementation
# Cross-platform. Should work in every platform supported by Godot
# Adapted from REST_v2_example.py by Cristiano Reis Monteiro <cristianomonteiro@gmail.com> Abr/2018


const UUID = preload("uuid.gd")

const ssl_validate_domain = true
# Number of events to hold before flushing the event queue
const event_queue_max_events = 64


# Game Keys
var game_key
var secret_key

# sandbox API urls
var base_url = "http://sandbox-api.gameanalytics.com" # "http://api.gameanalytics.com"

# global state to track changes when code is running
var state_config = {
	# the amount of seconds the client time is offset by server_time
	# will be set when init call receives server_time
	'client_ts_offset': 0,
	# will be updated when a new session is started
	'session_id': null,
	'session_start': null,
	# set if SDK is disabled or not - default enabled
	'enabled': true,
	# event queue - contains a list of event dictionaries to be JSON encoded
	'event_queue': []
}

func _http_free_request(request):
	remove_child(request)
	request.queue_free()

func _http_done(result, response_code, headers, body, http_request, response_handler):
	if response_code == 401:
		log_info("Unauthorized request, make sure you are using a valid game key")
		_http_free_request(http_request)
		return

	var json_result = JSON.parse(body.get_string_from_utf8())
	if json_result.error != OK:
		log_info("Invalid JSON recieved from server")
		_http_free_request(http_request)
		return

	self.call(response_handler, response_code, json_result.result)
	_http_free_request(http_request)

func _http_perform_request(endpoint, body, response_handler):
	if !state_config['enabled']:
		log_info("SDK Disabled, not performing any more requests")
		return

	# HTTPRequest needs to be in the tree to work properly
	var http_request = HTTPRequest.new()
	add_child(http_request)

	# TODO: Is request_complete guaranteed to be called? Otherwise, we have a memory leak
	http_request.connect("request_completed", self, "_http_done", [http_request, response_handler])

	var url = base_url + endpoint
	var json_payload = to_json(body)
	var headers = PoolStringArray([
		"Authorization: " + Marshalls.raw_to_base64(hmac_sha256(json_payload, secret_key)),
		"Content-Type: application/json"
	])

	var err = http_request.request(url, headers, ssl_validate_domain, HTTPClient.METHOD_POST, json_payload)
	if err != OK:
		log_info("Request failed, with godot error: " + str(err))
		_http_free_request(http_request)





func start_session():
	if state_config['session_id'] != null:
		log_info("Session already started. Not creating a new one")
		return

	state_config['session_id'] = UUID.v4()
	state_config['session_start'] = OS.get_unix_time_from_datetime(OS.get_datetime())

	log_info("Started session with id: " + str(state_config['session_id']))
	_init_request()

func stop_session():
	log_info("Stopped session with id: " + str(state_config['session_id']))

	var client_ts = OS.get_unix_time_from_datetime(OS.get_datetime())
	queue_event({
		'category': 'session_end',
		'length': client_ts - state_config['session_start']
	})
	_submit_events()
	state_config['session_id'] = null
	state_config['session_start'] = null


# func _notification(what):
#     if what == MainLoop.NOTIFICATION_WM_QUIT_REQUEST:
#         stop_session()

func _process(delta):
	if state_config['event_queue'].size() >= event_queue_max_events:
		_submit_events()






## Init Request

func update_client_ts_offset(server_ts):
	# calculate client_ts using offset from server time
	var client_ts = OS.get_unix_time_from_datetime(OS.get_datetime())
	var offset = client_ts - server_ts

	# If the difference is too small, ignore it
	state_config['client_ts_offset'] = 0 if offset < 10 else offset
	log_info('Client TS offset calculated to: ' + str(offset))

func _handle_init_response(response_code, body):
	if response_code < 200 or response_code >= 400:
		return

	state_config['enabled'] = body['enabled']
	state_config['server_ts'] = body['server_ts']
	update_client_ts_offset(state_config['server_ts'])

func _init_request():
	var default_annotations = _get_default_annotations()
	var init_payload = {
		'platform': default_annotations['platform'],
		'os_version': default_annotations['os_version'],
		'sdk_version': default_annotations['sdk_version']
	}

	var endpoint = "/v2/" + game_key + "/init"
	_http_perform_request(endpoint, init_payload, "_handle_init_response")





func _handle_submit_events_response(response_code, body):
	if response_code < 200 or response_code >= 400:
		return

	log_info("AYY: " + str(body))

func _submit_events():
	var endpoint = "/v2/" + game_key + "/events"
	_http_perform_request(endpoint, state_config['event_queue'], "_handle_submit_events_response")
	# It doesen't really matter if the request succeded, we are not going to send the events again
	state_config['event_queue'] = []



func queue_event(event):
	if typeof(event) != TYPE_DICTIONARY:
		log_info("Submitted an event that's not a dictionary")
		return

	event = _dict_assign(event, _get_default_annotations())
	state_config['event_queue'].append(event)










#func get_test_business_event_dict():
#	var event_dict = {
#		'category': 'business',
#		'amount': 999,
#		'currency': 'USD',
#		'event_id': 'Weapon:SwordOfFire',  # item_type:item_id
#		'cart_type': 'MainMenuShop',
#		'transaction_num': 1,  # should be incremented and stored in local db
#		'receipt_info': {'receipt': 'xyz', 'store': 'apple'}  # receipt is base64 encoded receipt
#	}
#	return event_dict
#
#
#func get_test_user_event():
#	var event_dict = {
#		'category': 'user'
#	}
#	return event_dict
#
#
#func get_test_session_end_event(length_in_seconds):
#	var event_dict = {
#		'category': 'session_end',
#		'length': length_in_seconds
#	}
#	return event_dict
#
#
#func get_test_design_event(event_id, value):
#	var event_dict = {
#		'category': 'design',
#		'event_id': event_id,
#		'value': value
#	}
#	return event_dict

static func _dict_assign(target, patch):
	for key in patch:
		target[key] = patch[key]
	return target


func _get_os_version():
	var platform = OS.get_name().to_lower()
	# Get version number on Android. Need something similar for iOS
	if platform == "android":
		var output = []
		# TODO: Why is this not used?
		var _pid = OS.execute("getprop", ["ro.build.version.release"], true, output)
		# Trimming new line char at the end
		output[0] = output[0].substr(0, output[0].length() - 1)
		return platform + " " + output[0]
	else:
		return OS.get_name().to_lower()

func _get_default_annotations():
	# For some reason GameAnalytics only accepts lower case. Weird but happened to me
	var platform = OS.get_name().to_lower()
	var os_version = _get_os_version()
	var sdk_version = 'rest api v2'
	var device = OS.get_model_name().to_lower()
	var manufacturer = OS.get_name().to_lower()
	var build_version = 'alpha 0.0.1'
	var engine_version = Engine.get_version_info()['string']

	var ts_offset = 0 if not state_config.has('client_ts_offset') else state_config['client_ts_offset']
	var client_ts = OS.get_unix_time_from_datetime(OS.get_datetime()) - ts_offset

	var default_annotations = {
		'v': 2,                                     # (required: Yes)
		'user_id': OS.get_unique_id().to_lower(),   # (required: Yes)
		#'ios_idfa': idfa,                          # (required: No - required on iOS)
		#'ios_idfv': idfv,                          # (required: No - send if found)
		#'google_aid'                               # (required: No - required on Android)
		#'android_id',                              # (required: No - send if set)
		#'googleplus_id',                           # (required: No - send if set)
		#'facebook_id',                             # (required: No - send if set)
		#'limit_ad_tracking',                       # (required: No - send if true)
		#'logon_gamecenter',                        # (required: No - send if true)
		#'logon_googleplay                          # (required: No - send if true)
		#'gender': 'male',                          # (required: No - send if set)
		#'birth_year                                # (required: No - send if set)
		#'progression                               # (required: No - send if a progression attempt is in progress)
		#'custom_01': 'ninja',                      # (required: No - send if set)
		#'custom_02                                 # (required: No - send if set)
		#'custom_03                                 # (required: No - send if set)
		'client_ts': client_ts,                     # (required: Yes)
		'sdk_version': sdk_version,                 # (required: Yes)
		'os_version': os_version,                   # (required: Yes)
		'manufacturer': manufacturer,               # (required: Yes)
		'device': device,                           # (required: Yes - if not possible set "unknown")
		'platform': platform,                       # (required: Yes)
		'session_id': state_config['session_id'],   # (required: Yes)
		#'build': build_version,                    # (required: No - send if set)
		'session_num': 1,                           # (required: Yes)
		#'connection_type': 'wifi',                 # (required: No - send if available)
		#'jailbroken                                # (required: No - send if true)
		#'engine_version': engine_version           # (required: No - send if set by an engine)
	}
	return default_annotations










func log_info(message):
	print("GameAnalytics: " + str(message))


func pool_byte_array_from_hex(hex):
	var out = PoolByteArray()

	for idx in range(0, hex.length(), 2):
		var hex_int = ("0x" + hex.substr(idx, 2)).hex_to_int()
		out.append(hex_int)

	return out

# TODO: This sucks, but its what we have right now
# Returns the hex encoded sha256 hash of buffer
func sha256(buffer):
	var path = "user://__ga__sha256_temp"
	var file = File.new()
	file.open(path, File.WRITE)
	file.store_buffer(buffer)
	file.close()
	var sha_hash = file.get_sha256(path)

	Directory.new().remove(path)

	return sha_hash

func hmac_sha256(message, key):
	# Hash key if length > 64
	if key.length() <= 64:
		key = key.to_utf8()
	else:
		key = key.sha256_buffer()

	# Right zero padding if key length < 64
	while key.size() < 64:
		key.append(0)


	var inner_key = PoolByteArray()
	var outer_key = PoolByteArray()

	for idx in range(0, 64):
		outer_key.append(key[idx] ^ 0x5c)
		inner_key.append(key[idx] ^ 0x36)


	var inner_hash = pool_byte_array_from_hex(sha256(inner_key + message.to_utf8()))
	var outer_hash = pool_byte_array_from_hex(sha256(outer_key + inner_hash))

	return outer_hash