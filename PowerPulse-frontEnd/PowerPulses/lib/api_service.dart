import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart'
    if (dart.library.html) 'package:web_socket_channel/html.dart';
import 'package:flutter/material.dart';
import 'main.dart'; // Import PowerDataProvider

class ApiService {
  // Base URL for your backend server.
  // This MUST match the IP address and port where your Node.js server.js is running.
  // Example: 'http://192.168.100.5:3001'
  static const String _baseServerUrl = 'http://192.168.100.5:3001';

  // Base URL for the MQTT Subscriber's WebSocket server.
  // This MUST match the IP address and port where your mqttSubscriber.js is running.
  // Example: 'ws://192.168.100.5:3002/ws'
  // Make sure the port (e.g., 3002) matches what you configure in mqttSubscriber.js (process.env.MQTT_SUBSCRIBER_PORT)
  static const String _wsServerUrl = 'ws://192.168.100.5:3002/ws';

  // API base URL for general data endpoints
  static const String baseUrl = '$_baseServerUrl/api';
  // API base URL for authentication endpoints
  static const String authUrl = '$_baseServerUrl/auth';

  // WebSocket channel instance
  static WebSocketChannel? _channel;
  static bool _isConnecting = false;
  static String? _authToken;
  static PowerDataProvider? _powerDataProvider; // Reference to the data provider

  /// Fetches current overall power data for the authenticated user.
  /// Corresponds to: `GET /api/power/current` in server.js
  /// Expected response keys: `power` (W), `energyToday` (Wh), `energyThisWeek` (Wh), `energyThisMonth` (Wh)
  static Future<Map<String, dynamic>> getCurrentPowerData(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/power/current'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      print('Failed to load current power data: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load current power data');
    }
  }

  /// Fetches aggregated consumption data (e.g., weekly, monthly) for the authenticated user.
  /// Corresponds to: `GET /api/power/consumption/aggregated?period=<period>` in server.js
  /// `period` can be 'weekly' or 'monthly'.
  /// Expected response: `{'totalConsumption': value_in_Wh}`
  static Future<Map<String, dynamic>> getAggregatedConsumption(String token, String period) async {
    final response = await http.get(
      Uri.parse('$baseUrl/power/consumption/aggregated?period=$period'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      print('Failed to load aggregated consumption for $period: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load aggregated consumption for $period');
    }
  }

  /// Fetches historical power data for the authenticated user (e.g., last 24 hours hourly).
  /// This corresponds to `getHistoricalData` in main.dart.
  /// Assumes a backend endpoint like `GET /api/power/history/user`
  /// with an optional `hours` query parameter.
  /// Expected response: `List<Map<String, dynamic>>` where each map has `timeStamp` and `energy` (Wh).
  static Future<List<Map<String, dynamic>>> getHistoricalData(String token, {int hours = 24}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/power/history/user?hours=$hours'), // Example endpoint with hours param
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      print('Failed to load historical data: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load historical data');
    }
  }

  /// Fetches historical power data for a specific device (e.g., last 7 days daily).
  /// Corresponds to: `GET /api/power/history/:deviceId` in server.js
  /// Expected response: `List<Map<String, dynamic>>` where each map has `date` and `consumed` (Wh).
  static Future<List<Map<String, dynamic>>> getDeviceDailyHistory(String token, String deviceId, {int? days}) async {
    final uri = days != null
        ? Uri.parse('$baseUrl/power/history/$deviceId?days=$days')
        : Uri.parse('$baseUrl/power/history/$deviceId');

    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      print('Failed to load device daily history: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load device daily history');
    }
  }

  /// Fetches summary statistics for a specific device.
  /// Corresponds to: `GET /api/devices/:deviceId/stats` in server.js
  /// Expected response keys: `todayConsumed` (Wh), `yesterdayConsumed` (Wh), `thisMonthConsumed` (Wh).
  static Future<Map<String, dynamic>> getDeviceStats(String token, String deviceId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/devices/$deviceId/stats'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      print('Failed to load device stats: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load device stats');
    }
  }

  /// Fetches the list of all registered devices for the authenticated user.
  /// Corresponds to: `GET /api/devices` in server.js
  static Future<List<Map<String, dynamic>>> getDevices(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/devices'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      print('Failed to load devices: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load devices');
    }
  }

  /// Fetches MQTT devices that are online and available for registration (not yet registered by any user).
  /// Corresponds to: `GET /api/mqtt-devices` in server.js
  static Future<List<Map<String, dynamic>>> getAvailableMqttDevices(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/mqtt-devices'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      print('Failed to load available MQTT devices: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load available MQTT devices');
    }
  }

  /// Toggles a device's power state (on/off).
  /// Corresponds to: `POST /api/devices/:deviceId/toggle` in server.js.
  static Future<Map<String, dynamic>> controlDevice(String token, String deviceId, bool turnOn) async {
    final response = await http.post(
      Uri.parse('$baseUrl/devices/$deviceId/toggle'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: json.encode({'turnOn': turnOn}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      print('Failed to control device: ${response.statusCode} ${response.body}');
      throw Exception('Failed to control device');
    }
  }

  /// Registers a new device for the authenticated user.
  /// Corresponds to: `POST /api/devices` in server.js.
  static Future<Map<String, dynamic>> addDevice(String token, String deviceId, String deviceName) async {
    final response = await http.post(
      Uri.parse('$baseUrl/devices'), // Corrected endpoint to /api/devices
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: json.encode({'deviceId': deviceId, 'name': deviceName}), // Corrected key to 'deviceId'
    );
    if (response.statusCode == 201) {
      return json.decode(response.body);
    } else {
      print('Failed to add device: ${response.statusCode} ${response.body}');
      throw Exception('Failed to add device');
    }
  }

  /// Removes a device for the authenticated user.
  /// Assumes a backend endpoint like `DELETE /api/devices/:deviceId`.
  static Future<void> removeDevice(String token, String deviceId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/devices/$deviceId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) { // Expect 200 OK or 204 No Content
      print('Failed to remove device: ${response.statusCode} ${response.body}');
      throw Exception('Failed to remove device');
    }
  }

  /// Sets or updates the monthly consumption target for a specific device.
  /// Corresponds to: `PUT /api/devices/:deviceId/target` (needs to be implemented in server.js)
  static Future<bool> setDeviceMonthlyTarget(String token, String deviceId, double targetWh) async {
    try {
      final response = await http.put(
        Uri.parse('$baseUrl/devices/$deviceId/target'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: json.encode({'monthlyTargetWh': targetWh}),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      print('Error setting device monthly target for $deviceId: $e');
      return false;
    }
  }


  /// Fetches device consumption breakdown for a specified period.
  /// Corresponds to: `GET /api/statistics/device-breakdown?period=<period>`
  /// Period can be 'today', 'current_week', 'current_month'.
  static Future<List<Map<String, dynamic>>> getDeviceConsumptionBreakdown(String token, String period) async {
    final response = await http.get(
      Uri.parse('$baseUrl/statistics/device-breakdown?period=$period'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      print('Failed to load device consumption breakdown for $period: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load device consumption breakdown for $period');
    }
  }

  /// Fetches consumption comparison data (current vs. previous for day, week, month).
  /// Corresponds to: `GET /api/statistics/consumption-comparison`
  /// Expected response: Map with keys 'daily', 'weekly', 'monthly', each having 'current' and 'previous' Wh values.
  static Future<Map<String, dynamic>> getConsumptionComparison(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/statistics/consumption-comparison'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      print('Failed to load consumption comparison: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load consumption comparison');
    }
  }

  /// Fetches notifications for the authenticated user.
  /// Corresponds to: `GET /api/notifications`
  /// Supports pagination with `page` and `limit`.
  static Future<Map<String, dynamic>> getNotifications(String token, {int page = 1, int limit = 20}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/notifications?page=$page&limit=$limit'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      return json.decode(response.body); // Expects { notifications: [], totalPages: X, currentPage: Y, totalCount: Z }
    } else {
      print('Failed to load notifications: ${response.statusCode} ${response.body}');
      throw Exception('Failed to load notifications');
    }
  }

  /// Marks a specific notification as read.
  /// Corresponds to: `POST /api/notifications/:notificationId/mark-read`
  static Future<bool> markNotificationAsRead(String token, String notificationId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/notifications/$notificationId/mark-read'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10)); // Added timeout

      if (response.statusCode == 200) {
        return true; // Successfully marked as read
      } else {
        print('Failed to mark notification as read: ${response.statusCode} ${response.body}');
        return false; // Failed to mark as read
      }
    } catch (e) {
      print('Error in ApiService.markNotificationAsRead: $e');
      return false; // Exception occurred
    }
  }

  /// Marks all notifications for the user as read.
  /// (This endpoint needs to be implemented in server.js if desired)
  /// Example: `POST /api/notifications/mark-all-read`
  static Future<void> markAllNotificationsAsRead(String token) async {
    // Placeholder: Implement this if you add the endpoint in server.js
    // final response = await http.post(
    //   Uri.parse('$baseUrl/notifications/mark-all-read'),
    //   headers: {'Authorization': 'Bearer $token'},
    // );
    // if (response.statusCode != 200) {
    //   print('Failed to mark all notifications as read: ${response.statusCode} ${response.body}');
    //   throw Exception('Failed to mark all notifications as read');
    // }
    print("markAllNotificationsAsRead called - backend endpoint not yet implemented in this example.");
    await Future.delayed(const Duration(milliseconds: 100)); // Simulate network
  }


  /// Logs in a user.
  /// Corresponds to: `POST /auth/login` in server.js
  /// Request body: `{'email': email, 'password': password}`
  /// Expected response: `{'token': '...', 'user': {'id': '...', 'name': '...', 'email': '...'}}`
  static Future<Map<String, dynamic>> loginUser(String email, String password) async {
    final response = await http.post(
      Uri.parse('$authUrl/login'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email, 'password': password}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body); // Expects {'token': '...', 'user': {...}}
    } else {
      throw Exception('Failed to login: ${response.statusCode} ${response.body}');
    }
  }

  /// Registers a new user.
  /// Corresponds to: `POST /auth/signup` in server.js
  /// Request body: `{'name': name, 'email': email, 'password': password}`
  static Future<void> signupUser(String email, String password, String name) async {
    final response = await http.post(
      Uri.parse('$authUrl/signup'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'name': name, 'email': email, 'password': password}),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception('Failed to signup: ${response.statusCode} ${response.body}');
    }
  }

  /// --- WebSocket Integration ---

  /// Connects to the WebSocket server for real-time updates.
  /// Call this once after a user successfully logs in and you have their token.
  static void connectWebSocket(String token, PowerDataProvider provider) {
    if (_channel != null) {
      print('[WebSocket] Already connected or channel exists. Disconnecting to ensure fresh connection.');
      _disconnectWebSocket();
    }
    if (_isConnecting) {
      print('[WebSocket] Connection in progress. Skipping new connection attempt.');
      return;
    }

    _authToken = token;
    _powerDataProvider = provider;
    _isConnecting = true;

    try {
      print('[WebSocket] Attempting to connect to $_wsServerUrl');
      _channel = WebSocketChannel.connect(Uri.parse(_wsServerUrl));

      // Send authentication token as the first message
      _channel!.sink.add(json.encode({'type': 'auth', 'token': _authToken}));
      print('[WebSocket] Sent authentication token.');

      _channel!.stream.listen(
        (message) {
          try {
            final Map<String, dynamic> data = json.decode(message);
            final String type = data['type'];
            final dynamic payload = data['payload'];

            switch (type) {
              case 'auth_success':
                print('[WebSocket] Authentication successful.');
                _powerDataProvider?.setWebSocketConnectionStatus(true, 'Connected');
                break;
              case 'auth_error':
                print('[WebSocket] Authentication failed: ${data['message']}');
                _powerDataProvider?.setWebSocketConnectionStatus(false, 'Auth Failed: ${data['message']}');
                _disconnectWebSocket();
                break;
              case 'current_power_update':
                if (payload is Map &&
                    payload.containsKey('power') &&
                    payload.containsKey('energyToday') &&
                    payload.containsKey('energyThisWeek') &&
                    payload.containsKey('energyThisMonth')) {
                  final double power = (payload['power'] as num).toDouble();
                  final double energyToday = (payload['energyToday'] as num).toDouble();
                  final double energyThisWeek = (payload['energyThisWeek'] as num).toDouble();
                  final double energyThisMonth = (payload['energyThisMonth'] as num).toDouble();
                  _powerDataProvider?.updateCurrentPowerAndPeriodicEnergy(power, energyToday, energyThisWeek, energyThisMonth);
                }
                break;
              case 'device_status_update':
                if (payload is Map && payload.containsKey('id') && payload.containsKey('status')) {
                  final String deviceId = payload['id'];
                  final bool newStatus = payload['status'];
                  _powerDataProvider?.updateDeviceStatusFromWs(deviceId, newStatus);
                }
                break;
              case 'initial_devices_update':
                if (payload is List) {
                  final List<Map<String, dynamic>> devices = List<Map<String, dynamic>>.from(payload);
                  _powerDataProvider?.setDevicesFromWs(devices);
                  print('[WebSocket] Initial device list updated.');
                }
                break;
              case 'new_notification': // Handle new notifications pushed by mqttSubscriber
                if (payload is Map<String, dynamic>) {
                  // Assuming PowerDataProvider has a method to handle incoming notifications
                  _powerDataProvider?.addNewNotificationFromWs(payload);
                  print('[WebSocket] Received new notification: ${payload['message']}');
                }
                break;
              default:
                print('[WebSocket] Unknown message type: $type');
            }
          } catch (e) {
            print('[WebSocket] Error parsing message: $e, original message: $message');
          }
        },
        onDone: () {
          _isConnecting = false;
          print('[WebSocket] Connection closed. Attempting to reconnect...');
          _powerDataProvider?.setWebSocketConnectionStatus(false, 'Disconnected. Reconnecting...');
          _reconnectWebSocket(_authToken!, provider); // Use _authToken for reconnect
        },
        onError: (error) {
          _isConnecting = false;
          print('[WebSocket] WebSocket error: $error. Attempting to reconnect...');
          _powerDataProvider?.setWebSocketConnectionStatus(false, 'Error: $error. Reconnecting...');
          _reconnectWebSocket(_authToken!, provider); // Use _authToken for reconnect
        },
      );
    } catch (e) {
      _isConnecting = false;
      print('[WebSocket] Failed to establish connection: $e');
      _powerDataProvider?.setWebSocketConnectionStatus(false, 'Failed to connect: $e');
    }
  }

  /// Disconnects the WebSocket.
  static void _disconnectWebSocket() {
    if (_channel != null) {
      print('[WebSocket] Disconnecting WebSocket.');
      _channel!.sink.close();
      _channel = null;
      _authToken = null;
      _powerDataProvider = null;
      _isConnecting = false;
    }
  }

  /// Attempts to reconnect the WebSocket after a delay.
  static void _reconnectWebSocket(String token, PowerDataProvider provider) {
    if (_isConnecting) return;
    Future.delayed(const Duration(seconds: 5), () {
      print('[WebSocket] Reconnecting...');
      connectWebSocket(token, provider);
    });
  }

  /// Call this when the user logs out to clean up the WebSocket connection.
  static void disconnectOnLogout() {
    _disconnectWebSocket();
  }
}
