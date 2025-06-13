import 'package:flutter/material.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import 'api_service.dart'; // Import the ApiService
import 'auth_provider.dart'; // CORRECT IMPORT FOR AuthProvider
import 'auth_page.dart'; // Import AuthPage
import 'package:animations/animations.dart'; // Import for PageTransitionSwitcher
import 'dart:math'; // For generating random mock data
import 'dart:async'; // Required for Future.delayed and Timer
import 'package:shared_preferences/shared_preferences.dart'; // For storing device targets (local cache only now)
import 'package:intl/intl.dart'; // For date formatting in NotificationPage
import 'package:smooth_page_indicator/smooth_page_indicator.dart'; // Import smooth_page_indicator

// Data Provider
class PowerDataProvider extends ChangeNotifier {
  double _currentPower = 0.0;
  // All energy values below are assumed to be in Wh coming from the API,
  // and will be converted to kWh for display.
  double _energyToday = 0.0; // Represents today's consumption in Wh
  double _energyThisWeek = 0.0; // Represents this week's consumption in Wh
  double _energyThisMonth = 0.0; // Represents this month's consumption in Wh

  double _energyYesterday = 0.0;
  double _energyLastWeek = 0.0;
  double _energyLastMonth = 0.0;

  // State for notifications
  List<Map<String, dynamic>> _notifications = []; // Raw data from API/WS
  int _unreadNotificationCount = 0;
  bool _isNotificationsLoading = false;
  String? _notificationsError;
  int _currentNotificationPage = 1;
  int _totalNotificationPages = 1;

  List<Map<String, dynamic>> _deviceConsumptionBreakdown = [];
  Map<String, dynamic> _consumptionComparison = {}; // This will now store live comparison data if API provided.

  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _energyData = []; // Used for the overall 24hr chart on StatisticsPage (hourly Wh)

  // Set this to true to use mock data when backend is unavailable
  static const bool MOCK_DATA_MODE = false;

  ThemeMode _themeMode = ThemeMode.dark; // Default to dark mode
  ThemeMode get themeMode => _themeMode;

  double get currentPower => _currentPower;

  // Getters for energy values, now returning kWh
  double get energyTodayKWh => _energyToday / 1000;
  double get energyThisWeekKWh => _energyThisWeek / 1000;
  double get energyThisMonthKWh => _energyThisMonth / 1000;
  double get energyYesterdayKWh => _energyYesterday / 1000;
  double get energyLastWeekKWh => _energyLastWeek / 1000;
  double get energyLastMonthKWh => _energyLastMonth / 1000;


  List<Map<String, dynamic>> get devices => _devices;
  List<Map<String, dynamic>> get deviceConsumptionBreakdown => _deviceConsumptionBreakdown;
  Map<String, dynamic> get consumptionComparison => _consumptionComparison;
  List<Map<String, dynamic>> get energyData => _energyData; // Still in Wh, converted in chart

  List<Map<String, dynamic>> get notifications => _notifications;
  int get unreadNotificationCount => _unreadNotificationCount;
  bool get isNotificationsLoading => _isNotificationsLoading;
  String? get notificationsError => _notificationsError;
  bool get canFetchMoreNotifications => _currentNotificationPage <= _totalNotificationPages && !_isNotificationsLoading;


  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  // WebSocket related properties
  bool _isWebSocketConnected = false;
  String _webSocketStatus = 'Disconnected';

  String get webSocketStatus => _webSocketStatus;
  bool get isWebSocketConnected => _isWebSocketConnected;

  PowerDataProvider() {
    // WebSocket connection is now handled by ApiService.connectWebSocket
    // and should be triggered after authentication.
  }

  void _setLoading(bool loading) {
    if (_isLoading == loading) return; // Avoid unnecessary notifications
    _isLoading = loading;
    Future.microtask(() => notifyListeners());
  }

  void _setError(String? errorMsg) {
    if (_error == errorMsg && errorMsg != null) return;
    if (_error == null && errorMsg == null) return;
    _error = errorMsg;
    Future.microtask(() => notifyListeners());
  }

  void toggleThemeMode() {
    _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    print("Theme mode toggled to: $_themeMode");
    notifyListeners();
  }

  // --- WebSocket Connection and Handling (Delegated to ApiService) ---
  // These methods are primarily for PowerDataProvider to update its internal state
  // based on messages received by ApiService's WebSocket.

  // Method to update current power and periodic energy values from WebSocket
  // This method is called by ApiService when a 'current_power_update' message is received.
  void updateCurrentPowerAndPeriodicEnergy(double power, double todayWh, double weekWh, double monthWh) {
    _currentPower = power;
    _energyToday = todayWh; // Stored as Wh
    _energyThisWeek = weekWh; // Stored as Wh
    _energyThisMonth = monthWh; // Stored as Wh
    notifyListeners();
    print('[PowerDataProvider] Updated via WS: P=${power}W, E_Today=${todayWh}Wh, E_Week=${weekWh}Wh, E_Month=${monthWh}Wh');
  }

  // Method to update a device's status from WebSocket
  void updateDeviceStatusFromWs(String deviceId, bool newStatus) {
    final deviceIndex = _devices.indexWhere((d) => d['id'] == deviceId);
    if (deviceIndex != -1) {
      if (_devices[deviceIndex]['status'] != newStatus) {
        _devices[deviceIndex]['status'] = newStatus;
        notifyListeners();
        print('[PowerDataProvider] Device $deviceId status updated to $newStatus via WS.');
      }
    } else {
      print('[PowerDataProvider] Received WS update for unknown device: $deviceId. Re-fetching devices.');
      final authProvider = AuthProvider(); // This might be problematic if not properly initialized.
      if (authProvider.isAuth) {
        fetchDevices(authProvider.token);
      }
    }
  }

  // Method to set the entire device list from WebSocket (e.g., initial sync)
  void setDevicesFromWs(List<Map<String, dynamic>> newDevices) {
    _devices = newDevices;
    notifyListeners();
    print('[PowerDataProvider] Devices list updated via WS initial sync.');
  }

  // Method to update WebSocket connection status (called by ApiService)
  void setWebSocketConnectionStatus(bool isConnected, String statusMessage) {
    _isWebSocketConnected = isConnected;
    _webSocketStatus = statusMessage;
    notifyListeners();
  }

  // Method to add a new notification received from WebSocket
  void addNewNotificationFromWs(Map<String, dynamic> notification) {
    // Prevent duplicates if the notification somehow arrives multiple times
    final existingIndex = _notifications.indexWhere((n) => n['_id'] == notification['_id']);
    if (existingIndex != -1) {
      // Update existing if necessary (e.g., if isRead status changed, though unlikely from WS new notif)
      _notifications[existingIndex] = notification; // Replace with new data
    } else {
    // Add to the beginning of the list for newest first
      _notifications.insert(0, notification);
    }

    if (!(notification['isRead'] as bool? ?? false)) {
      // Recalculate unread count to be safe, especially if duplicates were handled
      _unreadNotificationCount = _notifications.where((n) => !(n['isRead'] as bool? ?? false)).length;
    }
    print('[PowerDataProvider] Added/Updated notification from WS: ${notification['_id']}. Unread: $_unreadNotificationCount');
    notifyListeners();
  }


  @override
  void dispose() {
    // Ensure ApiService also disconnects its WebSocket when PowerDataProvider is disposed
    ApiService.disconnectOnLogout();
    super.dispose();
  }

  // --- HTTP Fetch Methods (for initial load and manual refresh) ---

  // NOTE: fetchCurrentPower only updates _currentPower (W) and the 'Today/Week/Month' totals from a potentially real-time source.
  // For 'Yesterday' and other comparison periods, fetchConsumptionComparison is the main source.
  Future<void> fetchCurrentPower(String? token) async {
    _setLoading(true);
    _setError(null);
    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Serving mock current power data.");
      await Future.delayed(const Duration(milliseconds: 200)); // Simulate network delay
      _currentPower = 157.8; // Mock W
      // These are here for mock mode fallback, but fetchConsumptionComparison is preferred for real data
      _energyToday = 23450.0; // Mock Wh
      _energyThisWeek = 150750.0; // Mock Wh
      _energyThisMonth = 650200.0; // Mock Wh
    } else {
      try {
        if (token == null) throw Exception("Not authenticated for fetching current power");
        final data = await ApiService.getCurrentPowerData(token);
        _currentPower = (data['power'] as num?)?.toDouble() ?? 0.0; // Expecting W
        // These values from current_power_data are less comprehensive than comparison data
        // For 'energyToday', 'energyThisWeek', 'energyThisMonth' from current_power_data,
        // it's possible this is only the current running total, not the full day's history.
        // It's better to rely on `fetchConsumptionComparison` for historical summaries.
        _energyToday = (data['energyToday'] as num?)?.toDouble() ?? 0.0; // Stored as Wh
        _energyThisWeek = (data['energyThisWeek'] as num?)?.toDouble() ?? 0.0; // Stored as Wh
        _energyThisMonth = (data['energyThisMonth'] as num?)?.toDouble() ?? 0.0; // Stored as Wh
      } catch (e) {
        _setError('Error fetching current power: ${e.toString()}');
        print('Error fetching current power: $e');
      }
    }
    _setLoading(false);
  }

  Future<void> fetchDevices(String? token) async {
    _setLoading(true); // Set loading true at the start
    _setError(null);
    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Serving mock devices.");
      await Future.delayed(const Duration(milliseconds: 200));
      _devices = [
        {'id': 'shellyplugus-mock001', 'name': 'Living Room Lamp', 'status': true, 'createdAt': DateTime.now().toIso8601String(), 'monthlyTargetWh': 10000.0},
        {'id': 'shellyplugus-mock002', 'name': 'Office PC Setup', 'status': false, 'createdAt': DateTime.now().toIso8601String(), 'monthlyTargetWh': 50000.0},
        {'id': 'shellyplugus-mock003', 'name': 'Kitchen Air Fryer', 'status': true, 'createdAt': DateTime.now().toIso8601String(), 'monthlyTargetWh': 15000.0},
        {'id': 'shellyplugus-mock004', 'name': 'Bedroom Fan', 'status': false, 'createdAt': DateTime.now().toIso8601String(), 'monthlyTargetWh': null}, // No target
      ];
    } else {
      try {
        if (token == null) throw Exception("Not authenticated for fetching devices");
        _devices = List<Map<String, dynamic>>.from(await ApiService.getDevices(token));
      } catch (e) {
        _setError('Error fetching devices: ${e.toString()}');
        print('Error fetching devices: $e');
        _devices = [];
      }
    }
    _setLoading(false);
  }

  Future<void> fetchDeviceConsumptionBreakdown(String? token, String period) async {
    _setLoading(true);
    _setError(null);
    if (MOCK_DATA_MODE) {
      await Future.delayed(const Duration(milliseconds: 300));
      _deviceConsumptionBreakdown = [
        {'deviceName': 'Living Room Lamp', 'consumedWh': Random().nextDouble() * 500},
        {'deviceName': 'Office PC Setup', 'consumedWh': Random().nextDouble() * 1200},
        {'deviceName': 'Kitchen Air Fryer', 'consumedWh': Random().nextDouble() * 800},
      ];
    } else {
      try {
        if (token == null) throw Exception("Not authenticated for fetching breakdown");
        _deviceConsumptionBreakdown = await ApiService.getDeviceConsumptionBreakdown(token, period);
      } catch (e) {
        _setError('Error fetching device breakdown: ${e.toString()}');
        _deviceConsumptionBreakdown = [];
      }
    }
    _setLoading(false);
  }

  // This method is crucial for populating all historical/comparison energy totals
  Future<void> fetchConsumptionComparison(String? token) async {
    _setLoading(true);
    _setError(null);
    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Serving mock consumption comparison.");
      await Future.delayed(const Duration(milliseconds: 300));
      // Mock system-wide comparison data
      _consumptionComparison = {
        'daily': {'current': 5200.0, 'previous': 6100.0}, // Wh
        'weekly': {'current': 35000.0, 'previous': 38000.0}, // Wh
        'monthly': {'current': 150000.0, 'previous': 160000.0}, // Wh
      };

      // Generate mock device breakdown for 'current_month' to sum it up
      final random = Random();
      final mockMonthlyDeviceBreakdown = [
        {'deviceName': 'Mock Lamp', 'consumedWh': random.nextDouble() * 5000 + 1000},
        {'deviceName': 'Mock PC', 'consumedWh': random.nextDouble() * 8000 + 2000},
        {'deviceName': 'Mock Fridge', 'consumedWh': random.nextDouble() * 3000 + 500},
        {'deviceName': 'Mock Heater', 'consumedWh': random.nextDouble() * 10000 + 3000},
      ];
      double sumOfMockDevicesMonthlyWh = mockMonthlyDeviceBreakdown.fold(0.0, (sum, item) => sum + ((item['consumedWh'] as num?)?.toDouble() ?? 0.0));

      _energyToday = (_consumptionComparison['daily']?['current'] as num?)?.toDouble() ?? 0.0;
      _energyYesterday = (_consumptionComparison['daily']?['previous'] as num?)?.toDouble() ?? 0.0;
      _energyThisWeek = (_consumptionComparison['weekly']?['current'] as num?)?.toDouble() ?? 0.0;
      _energyLastWeek = (_consumptionComparison['weekly']?['previous'] as num?)?.toDouble() ?? 0.0;
      _energyThisMonth = sumOfMockDevicesMonthlyWh; // Set monthly total from sum of mock devices
      _energyLastMonth = (_consumptionComparison['monthly']?['previous'] as num?)?.toDouble() ?? 0.0;

      print('--- MOCK DATA COMPARISON (After adjustment for monthly) ---');
      print('energyToday: $_energyToday Wh');
      print('energyYesterday: $_energyYesterday Wh');
      print('energyThisWeek: $_energyThisWeek Wh');
      print('energyThisMonth (from mock device sum): $_energyThisMonth Wh');
      print('----------------------------');

    } else {
      try {
        if (token == null) throw Exception("Not authenticated for fetching comparison");
        // ApiService.getConsumptionComparison should return a map with 'daily', 'weekly', 'monthly' keys,
        // each containing 'current' and 'previous' consumption in Wh.
        _consumptionComparison = await ApiService.getConsumptionComparison(token);
        print('Raw consumption comparison data from API: $_consumptionComparison'); // Debug: Check raw data

        // Fetch device breakdown for the current month to ensure consistency with individual device sums
        final List<Map<String, dynamic>> monthlyDeviceBreakdown = await ApiService.getDeviceConsumptionBreakdown(token, 'current_month');
        double sumOfDevicesMonthlyWh = monthlyDeviceBreakdown.fold(0.0, (sum, item) => sum + ((item['consumedWh'] as num?)?.toDouble() ?? 0.0));
        print('Sum of individual devices monthly consumption: $sumOfDevicesMonthlyWh Wh');

        // Assign the sum of individual devices to _energyThisMonth
        _energyThisMonth = sumOfDevicesMonthlyWh;

        // Populate other individual energy properties from the system-wide comparison data
        _energyToday = (_consumptionComparison['daily']?['current'] as num?)?.toDouble() ?? 0.0;
        _energyYesterday = (_consumptionComparison['daily']?['previous'] as num?)?.toDouble() ?? 0.0;
        _energyThisWeek = (_consumptionComparison['weekly']?['current'] as num?)?.toDouble() ?? 0.0;
        _energyLastWeek = (_consumptionComparison['weekly']?['previous'] as num?)?.toDouble() ?? 0.0;
        _energyLastMonth = (_consumptionComparison['monthly']?['previous'] as num?)?.toDouble() ?? 0.0; // This is previous month's system total

        print('--- API DATA COMPARISON (After adjustment for monthly) ---');
        print('energyToday: $_energyToday Wh');
        print('energyYesterday: $_energyYesterday Wh');
        print('energyThisWeek: $_energyThisWeek Wh');
        print('energyThisMonth (from device sum): $_energyThisMonth Wh');
        print('---------------------------');

      } catch (e) {
        _setError('Error fetching consumption comparison or device breakdown: ${e.toString()}');
        print('Error fetching consumption comparison or device breakdown: $e');
        _consumptionComparison = {}; // Clear comparison data on error
        // Also clear related summary values to reflect error
        _energyToday = 0.0;
        _energyYesterday = 0.0;
        _energyThisWeek = 0.0;
        _energyLastWeek = 0.0;
        _energyThisMonth = 0.0;
        _energyLastMonth = 0.0;
      }
    }
    _setLoading(false);
    notifyListeners(); // Notify after all comparison data is updated
  }

  // This fetches overall historical data for the StatisticsPage chart (hourly Wh)
  // The 'energy' values in _energyData list are still stored in Wh as returned by API.
  Future<void> fetchHistoricalData(String? token, {int hours = 24}) async {
    _setLoading(true);
    _setError(null);
    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Serving mock historical data.");
      await Future.delayed(const Duration(milliseconds: 300));
      final random = Random();
      _energyData = List.generate(hours, (index) {
        // Mocking hourly energy consumption in Wh
        return {
          'timeStamp': DateTime.now().subtract(Duration(hours: hours - 1 - index)).toIso8601String(),
          'energy': (random.nextDouble() * 1500 + 200).toDouble(), // Mock Wh per hour
          'deviceId': 'mock-device-general' // This field might not be needed for overall history
        };
      });
    } else {
      try {
        if (token == null) throw Exception("Not authenticated for fetching historical data");
        _energyData = List<Map<String, dynamic>>.from(await ApiService.getHistoricalData(token, hours: hours));
      } catch (e) {
        _setError('Error fetching historical data: ${e.toString()}');
        print('Error fetching historical data: $e');
        _energyData = [];
      }
    }
    _setLoading(false);
  }

  Future<void> addDevice(String? token, String deviceId, String name) async {
    _setLoading(true);
    _setError(null);
    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Simulating add device.");
      await Future.delayed(const Duration(milliseconds: 300));
      _devices.add({'id': deviceId, 'name': name, 'status': false, 'createdAt': DateTime.now().toIso8601String(), 'monthlyTargetWh': null});
    } else {
      try {
        if (token == null) throw Exception("Not authenticated for adding device");
        await ApiService.addDevice(token, deviceId, name);
        await fetchDevices(token); // Re-fetch devices to get the latest list from DB, which includes targets
      } catch (e) {
        _setError('Error adding device: ${e.toString()}');
        print('Error adding device: $e');
        rethrow;
      }
    }
    _setLoading(false);
  }

  Future<void> removeDevice(String? token, String deviceId) async {
    print("[PowerDataProvider] removeDevice called for $deviceId");
    _setLoading(true);
    _setError(null);
    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Simulating remove device.");
      await Future.delayed(const Duration(milliseconds: 300));
      _devices.removeWhere((device) => device['id'] == deviceId);
    } else {
      try {
        if (token == null) throw Exception("Not authenticated for removing device");
        await ApiService.removeDevice(token, deviceId);
        _devices.removeWhere((device) => device['id'] == deviceId); // Optimistic removal
      } catch (e) {
        print("[PowerDataProvider] Error removing device $deviceId: $e");
        _setError('Error removing device: ${e.toString()}');
        rethrow;
      }
    }
    _setLoading(false);
  }

  Future<void> controlDevice(String? token, String deviceId, bool status) async {
    print("[PowerDataProvider] controlDevice called for $deviceId, new status: $status");
    final deviceIndex = _devices.indexWhere((d) => d['id'] == deviceId);
    Map<String, dynamic>? originalDeviceData;

    if (deviceIndex != -1) {
      originalDeviceData = Map<String, dynamic>.from(_devices[deviceIndex]);
      print("[PowerDataProvider] Device '$deviceId' found at index $deviceIndex. Original status: ${originalDeviceData['status']}");

      List<Map<String, dynamic>> newDevicesList = List.from(_devices);
      newDevicesList[deviceIndex] = {
        ...newDevicesList[deviceIndex],
        'status': status
      };
      _devices = newDevicesList;

      print("[PowerDataProvider] Optimistically updated device status to $status for '$deviceId' by creating new list.");
      Future.microtask(() {
        notifyListeners();
        print("[PowerDataProvider] notifyListeners called after optimistic update for '$deviceId'.");
      });
    } else {
      print("[PowerDataProvider] Device '$deviceId' not found in local list for optimistic update.");
    }

    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Simulating control device for $deviceId to $status.");
      await Future.delayed(const Duration(milliseconds: 200));
    } else {
      try {
        if (token == null) throw Exception("Not authenticated for controlling device");
        print("[PowerDataProvider] Calling ApiService.controlDevice for '$deviceId', status: $status");
        await ApiService.controlDevice(token, deviceId, status);
        print("[PowerDataProvider] ApiService.controlDevice successful for '$deviceId'.");
      } catch (e) {
        print("[PowerDataProvider] Error controlling device '$deviceId': $e");
        if (deviceIndex != -1 && originalDeviceData != null) {
          List<Map<String, dynamic>> revertedDevicesList = List.from(_devices);
        revertedDevicesList[deviceIndex] = originalDeviceData;
        _devices = revertedDevicesList;

        print("[PowerDataProvider] Reverted device status for '$deviceId' to ${originalDeviceData['status']} due to error by creating new list.");
        Future.microtask(() {
          notifyListeners();
          print("[PowerDataProvider] notifyListeners called after reverting for '$deviceId' due to error.");
        });
        }
        rethrow;
      }
    }
  }

  // Method to fetch all initial data after login
  Future<void> fetchAllInitialData(String? token) async {
    if (token == null && !MOCK_DATA_MODE) {
      _setError("Authentication token not available for data fetching.");
      return;
    }
    _setLoading(true);
    // Fetch order is important: devices first to get targets, then energy data
    await fetchDevices(token); // Needed for monthlyTargetWh, and general device status
    await fetchCurrentPower(token); // For current power and immediate totals (often updated by WS)
    await fetchConsumptionComparison(token); // This now populates all daily/weekly/monthly sums including yesterday/last week/month
    await fetchHistoricalData(token); // For overall 24hr chart
    await fetchDeviceConsumptionBreakdown(token, 'today'); // For pie chart
    _setLoading(false);

    // Connect WebSocket after initial data is loaded and authenticated
    if (token != null) {
      ApiService.connectWebSocket(token, this); // Pass 'this' PowerDataProvider instance
    }
  }

  void clearDataOnLogout() {
    _currentPower = 0.0;
    _energyToday = 0.0;
    _energyThisWeek = 0.0;
    _energyThisMonth = 0.0;
    _energyYesterday = 0.0;
    _energyLastWeek = 0.0;
    _energyLastMonth = 0.0;
    _devices = [];
    _energyData = [];
    _deviceConsumptionBreakdown = [];
    _consumptionComparison = {};
    _error = null; // Clear error on logout
    _isLoading = false;
    ApiService.disconnectOnLogout(); // Delegate WebSocket disconnection to ApiService
    notifyListeners();
    print("[PowerDataProvider] Data cleared on logout.");
  }

  // --- Notification Specific Methods ---
  Future<void> fetchNotifications(String? token, {bool reset = false, bool markLoadingGlobal = true}) async {
    if (markLoadingGlobal) _setLoading(true); // For global loading indicator if needed
    _isNotificationsLoading = true;
    _setError(null);
    _notificationsError = null;

    if (reset) {
      _notifications = [];
      _unreadNotificationCount = 0;
    }

    if (MOCK_DATA_MODE) {
      print("[PowerDataProvider] MOCK_DATA_MODE: Serving mock notifications.");
      await Future.delayed(const Duration(milliseconds: 300));
      _notifications = [
        {'_id': 'mock-1', 'message': 'Device "Living Room Lamp" turned ON', 'type': 'device_online', 'timestamp': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(), 'isRead': false, 'severity': 'info'},
        {'_id': 'mock-2', 'message': 'High energy usage detected from "Kitchen Air Fryer"', 'type': 'high_usage_alert', 'timestamp': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(), 'isRead': true, 'severity': 'warning'},
        {'_id': 'mock-3', 'message': 'Device "Office PC Setup" is offline', 'type': 'device_offline', 'timestamp': DateTime.now().subtract(const Duration(days: 1)).toIso8601String(), 'isRead': false, 'severity': 'critical'},
      ];
      _unreadNotificationCount = _notifications.where((n) => !(n['isRead'] as bool? ?? false)).length;
    } else {
      try {
        if (token == null) {
          _notificationsError = "Not authenticated for fetching notifications";
          _notifications = [];
          _unreadNotificationCount = 0;
          _isNotificationsLoading = false;
          if (markLoadingGlobal) _setLoading(false);
          notifyListeners();
          return;
        }
        // Assuming ApiService.getNotifications returns a Map with 'notifications' list and pagination data
        final Map<String, dynamic> notificationData = await ApiService.getNotifications(token, page: reset ? 1 : _currentNotificationPage);
        
        final List<dynamic> fetchedList = notificationData['notifications'] as List? ?? [];
        final newNotifications = fetchedList.map((item) => item as Map<String, dynamic>).toList();

        if (reset) {
          _notifications = newNotifications;
          _currentNotificationPage = 1; // Reset page
        } else {
          // Add only new notifications to avoid duplicates if fetching more
          for (var newNotif in newNotifications) {
            if (!_notifications.any((n) => n['_id'] == newNotif['_id'])) {
              _notifications.add(newNotif);
            }
          }
        }
        _totalNotificationPages = notificationData['totalPages'] as int? ?? 1;
        if (newNotifications.isNotEmpty) {
           _currentNotificationPage++; // Increment for next fetch if successful
        }

        _unreadNotificationCount = _notifications.where((n) => !(n['isRead'] as bool? ?? false)).length;
      } catch (e) {
        _notificationsError = 'Error fetching notifications: ${e.toString()}';
        print('Error fetching notifications: $e');
        if (reset) { // Only clear if it was a fresh fetch attempt
          _notifications = [];
          _unreadNotificationCount = 0;
        }
      }
    }
    _isNotificationsLoading = false;
    if (markLoadingGlobal) _setLoading(false);
    notifyListeners(); // Notify after all updates
  }

  Future<bool> markNotificationAsRead(String? token, String notificationId) async {
    if (token == null) {
      _notificationsError = "Not authenticated for marking notification as read";
      notifyListeners();
      return false;
    }
    final notificationIndex = _notifications.indexWhere((n) => n['_id'] == notificationId);
    if (notificationIndex == -1 || (_notifications[notificationIndex]['isRead'] as bool? ?? false)) {
      return true; // Already read or not found, no action needed from client
    }

    try {
      final success = await ApiService.markNotificationAsRead(token, notificationId);
      if (success) {
        _notifications[notificationIndex]['isRead'] = true;
        _unreadNotificationCount = _notifications.where((n) => !(n['isRead'] as bool? ?? false)).length;
        notifyListeners();
        return true;
      } else {
        _notificationsError = "Failed to mark notification as read on server.";
        notifyListeners();
        return false;
      }
    } catch (e) {
      _notificationsError = 'Error marking notification as read: ${e.toString()}';
      print('Error marking notification as read: $e');
      notifyListeners();
      return false;
    }
  }

  Future<void> markAllNotificationsAsRead(String? token) async {
    if (token == null) {
      _notificationsError = "Not authenticated";
      notifyListeners();
      return;
    }
    List<String> unreadIds = _notifications
        .where((n) => !(n['isRead'] as bool? ?? false))
        .map((n) => n['_id'] as String)
        .toList();

    if (unreadIds.isEmpty) return;

    // Optimistically update UI
    for (var notification in _notifications) {
      if (!(notification['isRead'] as bool? ?? false)) {
        notification['isRead'] = true;
      }
    }
    _unreadNotificationCount = 0;
    notifyListeners();

    // Attempt to update backend for each.
    // TODO: Implement a backend endpoint /api/notifications/mark-all-read for efficiency.
    for (String id in unreadIds) {
      ApiService.markNotificationAsRead(token, id).catchError((e) {
        print("Background mark-read failed for $id: $e");
        // Optionally, find this notification and revert its isRead status in UI
        // and re-increment unread count if precise sync is critical.
      });
    }
  }

  Future<bool> updateDeviceMonthlyTarget(String? token, String deviceId, double targetWh) async {
    if (token == null) {
      _setError("Not authenticated to update device target.");
      notifyListeners(); // Notify about the error
      return false;
    }
    _setLoading(true); // Indicate loading state
    try {
      final success = await ApiService.setDeviceMonthlyTarget(token, deviceId, targetWh);
      if (success) {
        // After successful API call, force a re-fetch of all devices to ensure consistency
        // This will update the _devices list and notify listeners
        await fetchDevices(token);
        _setLoading(false);
        // notifyListeners() is already called by fetchDevices, so no need to call it here again.
        return true;
      }
      _setError("Failed to update device target on server.");
    } catch (e) {
      _setError('Error updating device target: ${e.toString()}');
      print('Error updating device target: $e');
    }
    _setLoading(false);
    notifyListeners(); // Notify UI of error or completion if fetchDevices didn't handle it
    return false;
  }
}


// --- SplashScreen Widget ---
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacityAnimation;
  late Animation<double> _textOpacityAnimation;
  late Animation<Offset> _slideAnimation;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2000), // Splash logo animation duration (2 seconds)
      vsync: this,
    );

    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );

    _slideAnimation = Tween<Offset>(begin: const Offset(-1.5, 0.0), end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic), // Smooth slide for logo
    );

    _textOpacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _controller,
          curve: const Interval(0.6, 1.0, curve: Curves.easeIn)), // Text fades in during last 40% of 2s
    );
    _controller.forward();
    print("[SplashScreen] initState: Animations initialized and started.");
  }

  @override
  void dispose() {
    _controller.dispose();
    print("[SplashScreen] dispose: Animation controller disposed.");
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    print("[SplashScreen] build method called.");
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.white,
              primaryAppBlue,
            ],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _opacityAnimation,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SlideTransition(
                  position: _slideAnimation,
                  child: Image.asset(
                    'assets/images/2.png', // Ensure this asset exists and is in pubspec.yaml
                    height: 450,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      print("[SplashScreen] Error loading image assets/images/2.png: $error");
                      return Icon(Icons.error, color: Colors.red, size: 100); // Fallback icon
                    },
                  ),
                ),
                const SizedBox(height: 20),
                FadeTransition(
                  opacity: _textOpacityAnimation,
                  child: Text(
                    "Power at your finger tips".toUpperCase(),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white.withOpacity(0.9),
                      fontFamily: 'Montserrat',
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}


void main() {
  print("[main] Application starting...");
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (ctx) {
          print("[main] AuthProvider created.");
          return AuthProvider();
        }),
        ChangeNotifierProxyProvider<AuthProvider, PowerDataProvider>(
          create: (ctx) {
            print("[main] PowerDataProvider created via ProxyProvider.");
            Provider.of<AuthProvider>(ctx, listen: false).tryAutoLogin().catchError((e) {
              print("Error during initial tryAutoLogin from ProxyProvider: $e");
            });
            return PowerDataProvider();
          },
          update: (ctx, auth, previousPowerData) {
            print("[main] PowerDataProvider update triggered. Auth state: ${auth.isAuth}");
            if (!auth.isAuth) {
              previousPowerData?.clearDataOnLogout();
            } else {
              if (auth.token != null && previousPowerData != null) { // Added null check for previousPowerData
                ApiService.connectWebSocket(auth.token!, previousPowerData);
                // Fetch notifications if not already loaded after WebSocket connects
                if (previousPowerData.notifications.isEmpty && !previousPowerData.isLoading && !previousPowerData.isNotificationsLoading) {
                  print("[ChangeNotifierProxyProvider] Auth detected, fetching initial notifications.");
                  previousPowerData.fetchNotifications(auth.token, reset: true, markLoadingGlobal: false);
                }
              }
            }
            return previousPowerData ?? PowerDataProvider();
          },
        ),
      ],
      child: const MyApp(),
    ),
  );
  print("[main] runApp called.");
}

// Define our color palette for the new theme
const Color primaryAppBlue = Color(0xFF00A1FF);
const Color lightAccentBlue = Color(0xFF33B4FF);
const Color appDarkBackground = Color(0xFF0D1117);
const Color appSurfaceColor = Color(0xFF161B22);
const Color appOnPrimaryColor = Colors.white;
const Color appPrimaryTextColor = Colors.white;
final Color appSecondaryTextColor = Colors.blueGrey[300]!;

// Light Theme Text Colors
const Color lightThemePrimaryTextColor = Colors.black87;
final Color lightThemeSecondaryTextColor = Colors.grey[700]!;


class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {

  // Define a light theme
  final ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    primaryColor: primaryAppBlue,
    scaffoldBackgroundColor: Colors.grey[100],
    fontFamily: 'OpenSans',
    colorScheme: ColorScheme.light(
      primary: primaryAppBlue,
      secondary: lightAccentBlue,
      surface: Colors.white,
      background: Colors.grey[100]!,
      error: Colors.red.shade700,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: lightThemePrimaryTextColor,
      onBackground: lightThemePrimaryTextColor,
      onError: Colors.white,
      tertiary: Colors.teal.shade300, // Added for more color options
      errorContainer: Colors.red.shade100, // Added for more color options
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: primaryAppBlue,
      elevation: 2,
      titleTextStyle: TextStyle(
        fontFamily: 'Montserrat',
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
      iconTheme: IconThemeData(color: Colors.white),
    ),
    textTheme: TextTheme(
      displayLarge: TextStyle(fontFamily: 'Montserrat', color: lightThemePrimaryTextColor, fontWeight: FontWeight.bold),
      displayMedium: TextStyle(fontFamily: 'Montserrat', color: lightThemePrimaryTextColor, fontWeight: FontWeight.bold),
      displaySmall: TextStyle(fontFamily: 'Montserrat', color: lightThemePrimaryTextColor, fontWeight: FontWeight.bold),
      headlineMedium: TextStyle(fontFamily: 'Montserrat', color: lightThemePrimaryTextColor, fontWeight: FontWeight.w600, fontSize: 22),
      headlineSmall: TextStyle(fontFamily: 'Montserrat', color: lightThemePrimaryTextColor, fontWeight: FontWeight.w600, fontSize: 18),
      titleLarge: TextStyle(fontFamily: 'Montserrat', color: lightThemePrimaryTextColor, fontWeight: FontWeight.w600),

      titleMedium: TextStyle(fontFamily: 'OpenSans', color: lightThemePrimaryTextColor, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(fontFamily: 'OpenSans', color: lightThemePrimaryTextColor, fontSize: 16),
      bodyMedium: TextStyle(fontFamily: 'OpenSans', color: lightThemeSecondaryTextColor, fontSize: 14),
      bodySmall: TextStyle(fontFamily: 'OpenSans', color: lightThemeSecondaryTextColor, fontSize: 12),
      labelLarge: TextStyle(fontFamily: 'OpenSans', color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
    ).apply(
      bodyColor: lightThemePrimaryTextColor,
      displayColor: lightThemePrimaryTextColor,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryAppBlue,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontFamily: 'OpenSans', fontSize: 16, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
     textButtonTheme: TextButtonThemeData(
       style: TextButton.styleFrom(
         foregroundColor: lightAccentBlue, // Consistent with the new palette
         textStyle: const TextStyle(fontFamily: 'Roboto', fontWeight: FontWeight.w600),
         // You can customize hover/highlight colors here if needed for desktop
       ),
     ),
    iconTheme: const IconThemeData(
      color: lightAccentBlue,
    ),
    cardTheme: CardTheme(
      color: Colors.transparent, // Set to transparent to show gradient
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: primaryAppBlue,
      unselectedItemColor: Colors.grey[600],
      type: BottomNavigationBarType.fixed,
      elevation: 4,
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: TextStyle(fontFamily: 'OpenSans', color: lightThemeSecondaryTextColor),
      hintStyle: TextStyle(fontFamily: 'OpenSans', color: lightThemeSecondaryTextColor.withOpacity(0.7)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: Colors.grey[400]!),
      ),
      enabledBorder:  OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: Colors.grey[400]!),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: const BorderSide(color: primaryAppBlue, width: 2.0),
      ),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
      titleTextStyle: const TextStyle(fontFamily: 'Montserrat', color: lightThemePrimaryTextColor, fontSize: 18, fontWeight: FontWeight.bold),
      contentTextStyle: TextStyle(fontFamily: 'OpenSans', color: lightThemeSecondaryTextColor, fontSize: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Colors.grey[800],
      contentTextStyle: const TextStyle(fontFamily: 'OpenSans', color: Colors.white),
      actionTextColor: lightAccentBlue,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
    ),
     switchTheme: SwitchThemeData(
      thumbColor: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
        if (states.contains(MaterialState.selected)) {
          return lightAccentBlue;
        }
        return primaryAppBlue.withOpacity(0.7);
      }),
      trackColor: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
        if (states.contains(MaterialState.selected)) {
          return lightAccentBlue.withOpacity(0.5);
        }
        return primaryAppBlue.withOpacity(0.3);
      }),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primaryAppBlue,
      linearTrackColor: Colors.grey[300],
      circularTrackColor: Colors.grey[300],
    ),
    dividerColor: Colors.grey[300],
  );

  // Your existing dark theme
  final ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    primaryColor: primaryAppBlue,
    scaffoldBackgroundColor: appDarkBackground,
    fontFamily: 'OpenSans',
    colorScheme: ColorScheme.dark(
      primary: primaryAppBlue,
      secondary: lightAccentBlue,
      surface: appSurfaceColor,
      background: appDarkBackground,
      error: Colors.redAccent[100]!,
      onPrimary: appOnPrimaryColor,
      onSecondary: appOnPrimaryColor,
      onSurface: appPrimaryTextColor,
      onBackground: appPrimaryTextColor,
      onError: appPrimaryTextColor,
      tertiary: Colors.cyan.shade600, // Added for more color options
      errorContainer: Colors.red.shade800.withOpacity(0.5), // Added
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: appSurfaceColor,
      elevation: 1,
      titleTextStyle: TextStyle(
        fontFamily: 'Montserrat',
        color: appPrimaryTextColor,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
      iconTheme: IconThemeData(color: lightAccentBlue),
    ),
    textTheme: TextTheme(
      displayLarge: TextStyle(fontFamily: 'Montserrat', color: appPrimaryTextColor, fontWeight: FontWeight.bold),
      displayMedium: TextStyle(fontFamily: 'Montserrat', color: appPrimaryTextColor, fontWeight: FontWeight.bold),
      displaySmall: TextStyle(fontFamily: 'Montserrat', color: appPrimaryTextColor, fontWeight: FontWeight.bold),
      headlineMedium: TextStyle(fontFamily: 'Montserrat', color: appPrimaryTextColor, fontWeight: FontWeight.w600, fontSize: 22),
      headlineSmall: TextStyle(fontFamily: 'Montserrat', color: appPrimaryTextColor, fontWeight: FontWeight.w600, fontSize: 18),
      titleLarge: TextStyle(fontFamily: 'Montserrat', color: appPrimaryTextColor, fontWeight: FontWeight.w600),

      titleMedium: TextStyle(fontFamily: 'OpenSans', color: appPrimaryTextColor, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(fontFamily: 'OpenSans', color: appPrimaryTextColor, fontSize: 16),
      bodyMedium: TextStyle(fontFamily: 'OpenSans', color: appSecondaryTextColor, fontSize: 14),
      bodySmall: TextStyle(fontFamily: 'OpenSans', color: appSecondaryTextColor, fontSize: 12),
      labelLarge: TextStyle(fontFamily: 'OpenSans', color: appOnPrimaryColor, fontWeight: FontWeight.bold, fontSize: 16),
    ).apply(
      bodyColor: appPrimaryTextColor,
      displayColor: appPrimaryTextColor,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryAppBlue,
        foregroundColor: appOnPrimaryColor,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontFamily: 'OpenSans', fontSize: 16, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: lightAccentBlue,
        textStyle: const TextStyle(fontFamily: 'OpenSans', fontWeight: FontWeight.w600),
      ),
    ),
    iconTheme: const IconThemeData(
      color: lightAccentBlue,
    ),
    cardTheme: CardTheme(
      color: Colors.transparent, // Set to transparent to show gradient
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: appSurfaceColor,
      selectedItemColor: lightAccentBlue,
      unselectedItemColor: appSecondaryTextColor,
      type: BottomNavigationBarType.fixed,
      elevation: 4,
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: TextStyle(fontFamily: 'OpenSans', color: appSecondaryTextColor),
      hintStyle: TextStyle(fontFamily: 'OpenSans', color: appSecondaryTextColor.withOpacity(0.7)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: appSecondaryTextColor.withOpacity(0.5)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: appSecondaryTextColor.withOpacity(0.5)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: const BorderSide(color: lightAccentBlue, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: Colors.redAccent[100]!, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.0),
        borderSide: BorderSide(color: Colors.redAccent[100]!, width: 2.0),
      ),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: appSurfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
      titleTextStyle: const TextStyle(fontFamily: 'Montserrat', color: appPrimaryTextColor, fontSize: 18, fontWeight: FontWeight.bold),
      contentTextStyle: TextStyle(fontFamily: 'OpenSans', color: appSecondaryTextColor, fontSize: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: appSurfaceColor,
      contentTextStyle: const TextStyle(fontFamily: 'OpenSans', color: appPrimaryTextColor),
      actionTextColor: lightAccentBlue,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
        if (states.contains(MaterialState.selected)) {
          return lightAccentBlue;
        }
        return appSecondaryTextColor.withOpacity(0.6);
      }),
      trackColor: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
        if (states.contains(MaterialState.selected)) {
          return lightAccentBlue.withOpacity(0.5);
        }
        return appSurfaceColor.withOpacity(0.7);
      }),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: lightAccentBlue,
      linearTrackColor: appSurfaceColor.withOpacity(0.5),
      circularTrackColor: appSurfaceColor.withOpacity(0.5),
    ),
    dividerColor: appSecondaryTextColor.withOpacity(0.3),
  );

  late Future<void> _initializationFuture;

  @override
  void initState() {
    super.initState();
    _initializationFuture = _initializeApp();
    print("[MyApp] initState: _initializeApp future set.");
  }

  Future<void> _initializeApp() async {
    print("[MyApp] _initializeApp: Starting delay for splash screen visibility (2000ms).");
    await Future.delayed(const Duration(milliseconds: 2000));
    print("[MyApp] _initializeApp: Delay finished. FutureBuilder should now proceed.");
  }

  @override
  Widget build(BuildContext context) {
    print("[MyApp] build method called.");
    return Consumer<PowerDataProvider>(
      builder: (context, powerData, _) {
        print("[MyApp] Consumer<PowerDataProvider> building. ThemeMode: ${powerData.themeMode}");
        return MaterialApp(
          title: 'PowerPulse',
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: powerData.themeMode,
          home: Consumer<AuthProvider>(
            builder: (context, auth, child) {
              print("[MyApp] Consumer<AuthProvider> building. Auth.isAuth: ${auth.isAuth}, Auth.isLoading: ${auth.isLoading}");
              return FutureBuilder(
                future: _initializationFuture,
                builder: (ctx, snapshot) {
                  print("[MyApp] FutureBuilder: snapshot.connectionState = ${snapshot.connectionState}, auth.isAuth = ${auth.isAuth}, auth.isLoading = ${auth.isLoading}");
                  Widget currentScreen;
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    print("[MyApp] FutureBuilder: Showing SplashScreen.");
                    currentScreen = const SplashScreen(key: ValueKey('splash'));
                  } else {
                    currentScreen = auth.isAuth
                        ? const HomePage(key: ValueKey('home'))
                        : AuthPage(key: const ValueKey('auth'));
                    print("[MyApp] FutureBuilder: Showing ${auth.isAuth ? 'HomePage' : 'AuthPage'}.");
                  }
                  return AnimatedSwitcher(
                     duration: const Duration(milliseconds: 1500), // Slowed down a bit more
                     transitionBuilder: (Widget child, Animation<double> animation) {
                        print("[MyApp] AnimatedSwitcher: Transitioning to ${child.key}.");
                        if (child.key == const ValueKey('auth')) {
                          // AuthPage: Slide in from the left with a bounce
                          return SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(-1.0, 0.0), // Start off-screen to the left
                              end: Offset.zero,
                            ).animate(CurvedAnimation(
                              parent: animation,
                              curve: Curves.bounceOut, // This curve creates multiple bounces!
                            )),
                            child: child,
                          );
                        } else if (child.key == const ValueKey('home')) {
                          // HomePage: Gentle scale up and fade in
                          final CurvedAnimation curvedAnimation = CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeInOutCubic,
                          );
                          return ScaleTransition(
                            scale: Tween<double>(begin: 0.95, end: 1.0).animate(curvedAnimation),
                            child: FadeTransition(
                              opacity: curvedAnimation,
                              child: child,
                            ),
                          );
                        }
                        // SplashScreen (and any other fallback): Simple fade
                        return FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                    },
                    child: currentScreen,
                  );
                 },
              );
            },
          ),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  final Map<String, IconData> deviceIcons = {
    "Air Condition": Icons.ac_unit,
    "Computer": Icons.computer,
    "Livingroom": Icons.tv,
    "CCTV Camera": Icons.camera_alt,
    "Fan": Icons.air, // Replaced mode_fan_outlined
    "Light": Icons.lightbulb_outline, // Added a new icon
    "Heater": Icons.thermostat, // Added a new icon
    "Refrigerator": Icons.kitchen, // Added a new icon
  };

  late List<Widget> _pages;

  final List<String> _appBarTitles = [
    'Power Usage',
    'Energy Insights', // Updated title
    'Notifications',
    'Settings'
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _triggerInitialDataFetch();
      }
    );
    _pages = [
      HomePageContent(deviceIcons: deviceIcons),
      StatisticsPage(),
      NotificationPage(),
      SettingsPage(),
    ];
  }

  Future<void> _triggerInitialDataFetch() async {
     final authProvider = Provider.of<AuthProvider>(context, listen: false);
     final powerData = Provider.of<PowerDataProvider>(context, listen: false);
     if (authProvider.isAuth && !powerData.isLoading && (powerData.devices.isEmpty || powerData.energyData.isEmpty || powerData.consumptionComparison.isEmpty)) {
        await powerData.fetchAllInitialData(authProvider.token);
     }
  }

  void _fetchAllData(String? token) {
    final powerData = Provider.of<PowerDataProvider>(context, listen: false);
    powerData.fetchAllInitialData(token);
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final powerData = Provider.of<PowerDataProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitles[_currentIndex]),
        actions: [
          // WebSocket connection status indicator
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Tooltip(
              message: 'WebSocket Status: ${powerData.webSocketStatus}',
              child: Icon(
                powerData.isWebSocketConnected ? Icons.cloud_done : Icons.cloud_off,
                color: powerData.isWebSocketConnected ? Colors.greenAccent : Colors.redAccent,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: authProvider.isAuth
                ? () => _fetchAllData(authProvider.token)
                : null,
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: 'Statistics',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications),
            label: 'Notification',
          ),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}

class HomePageContent extends StatelessWidget {
  final Map<String, IconData> deviceIcons;

  const HomePageContent({super.key, required this.deviceIcons});

  @override
  Widget build(BuildContext context) {
    final powerData = Provider.of<PowerDataProvider>(context);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    String getDynamicGreeting(String? userName) {
      final hour = DateTime.now().hour;
      String timeOfDayGreeting;
      if (hour < 12) {
        timeOfDayGreeting = 'Good Morning';
      } else if (hour < 17) {
        timeOfDayGreeting = 'Good Afternoon';
      } else {
        timeOfDayGreeting = 'Good Evening';
      }
      return "$timeOfDayGreeting ☀️\n${userName ?? 'Valued User'}";
    }
    final authProvider = Provider.of<AuthProvider>(context);
    if (!authProvider.isAuth) {
       return const Center(child: Text("Please log in to view content."));
    }

    if (powerData.isLoading && powerData.currentPower == 0.0 && powerData.devices.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (powerData.error != null && powerData.currentPower == 0.0 && powerData.devices.isEmpty && powerData.energyTodayKWh == 0.0) { // Check kWh getter
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 50),
              const SizedBox(height: 10),
              Text('Error: ${powerData.error}', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 10),
              Text('Please check your backend server and network connection, then tap refresh in the app bar.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        )
      );
    }

    double maxPowerForPercentage = 1000.0; // Adjusted for more sensitive load indication (in Watts)
    double currentPowerPercentage = (powerData.currentPower / maxPowerForPercentage).clamp(0.0, 1.0);

    return RefreshIndicator(
      color: lightAccentBlue,
      backgroundColor: Theme.of(context).colorScheme.surface,
      onRefresh: () async {
        final token = authProvider.token;
        await powerData.fetchAllInitialData(token); // Re-fetch all data on refresh
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 0.0, bottom: 12.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Image.asset(
                      isDarkMode ? 'assets/images/1.png' : 'assets/images/2.png', // Ensure these assets exist and are in pubspec.yaml
                      height: 190,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        print("[HomePageContent] Error loading image: $error");
                        return Icon(Icons.broken_image, color: Colors.red, size: 50); // Fallback icon
                      },
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        getDynamicGreeting(authProvider.user?['name'] as String?),
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.wb_sunny,
                            size: 20,
                            color: !isDarkMode ? Colors.orangeAccent : Theme.of(context).textTheme.bodyMedium?.color),
                        const SizedBox(width: 4),
                        Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: isDarkMode,
                            onChanged: (value) {
                              Provider.of<PowerDataProvider>(context, listen: false).toggleThemeMode();
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.nightlight_round,
                            size: 20,
                            color: isDarkMode ? lightAccentBlue : Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.6)),
                      ],
                    ),
                  ],
                ),
              ),
              Center(
                child: CircularPercentIndicator(
                  radius: 120.0,
                  lineWidth: 13.0,
                  animation: true,
                  percent: currentPowerPercentage,
                  center: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "${(currentPowerPercentage * 100).toStringAsFixed(0)}%",
                        style: TextStyle(
                          fontSize: 35.0,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Current Load",
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                       Text(
                        "${powerData.currentPower.toStringAsFixed(1)} W", // Display in Watts
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                  progressColor: Theme.of(context).colorScheme.primary,
                  backgroundColor: Theme.of(context).colorScheme.surface.withOpacity(0.7),
                  circularStrokeCap: CircularStrokeCap.round,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                "Energy Overview",
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              // Displaying energy in kWh
              _buildInfoCard(
                  context,
                  'Total Energy Today',
                  '${powerData.energyTodayKWh.toStringAsFixed(2)} kWh', // Display in kWh
                  Icons.offline_bolt,
                  Theme.of(context).colorScheme.secondary),
              const SizedBox(height: 10),
              _buildInfoCard(
                  context,
                  'Total Energy Yesterday', // New card for yesterday
                  '${powerData.energyYesterdayKWh.toStringAsFixed(2)} kWh', // Display in kWh
                  Icons.watch_later_outlined, // Appropriate icon
                  Theme.of(context).colorScheme.tertiary ?? Theme.of(context).colorScheme.secondary), // A different color for distinction
              const SizedBox(height: 10),
              _buildInfoCard(
                  context,
                  'Total Energy This Week',
                  '${powerData.energyThisWeekKWh.toStringAsFixed(2)} kWh', // Display in kWh
                  Icons.calendar_view_week,
                  Theme.of(context).colorScheme.tertiary ?? Theme.of(context).colorScheme.secondary),
              const SizedBox(height: 10),
              _buildInfoCard(
                  context,
                  'Total Energy This Month',
                  '${powerData.energyThisMonthKWh.toStringAsFixed(2)} kWh', // Display in kWh
                  Icons.calendar_month,
                  Theme.of(context).colorScheme.errorContainer),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Devices",
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle, size: 30),
                    onPressed: () {
                      _showAddDeviceDialog(context, powerData);
                    },
                  )
                ],
              ),
              const SizedBox(height: 10),
              powerData.devices.isEmpty && !powerData.isLoading
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40.0, horizontal: 20.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.devices_other_outlined, size: 60, color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7)),
                          const SizedBox(height: 16),
                          Text("No Devices Yet", style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          Text("Tap the '+' button above to add your first PowerPulse device and start monitoring!", textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ))
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: powerData.devices.length,
                    itemBuilder: (context, index) {
                      final device = powerData.devices[index];
                      return _buildDeviceCard(
                        context,
                        device['name']?.toString() ?? 'Unknown Device',
                        device['id']?.toString() ?? 'N/A',
                        device['status'] as bool? ?? false,
                        deviceIcons,
                        powerData
                      );
                    },
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, String title, String value, IconData icon, Color iconColor) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return Card(
      elevation: Theme.of(context).cardTheme.elevation ?? 2,
      shape: Theme.of(context).cardTheme.shape,
      clipBehavior: Clip.antiAlias,
      child: Container( // Wrap content in Container for gradient
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, primaryAppBlue.withOpacity(0.7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12.0), // Match card border radius
        ),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Row(
          children: [
            Icon(
              icon,
              color: isDarkMode ? Colors.white.withOpacity(0.9) : Colors.white, // Changed icon color for gradient
              size: 40
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white // Changed text color for gradient
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: Colors.white70 // Changed text color for gradient
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddDeviceDialog(BuildContext context, PowerDataProvider powerData) async {
    final TextEditingController _nameController = TextEditingController();
    String? _selectedMqttDeviceId;
    List<String> mqttDeviceIds = [];
    String? dialogError;
    bool isLoadingMqttDevices = true;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20.0)),
      ),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            if (isLoadingMqttDevices && dialogError == null) {
              if (PowerDataProvider.MOCK_DATA_MODE) {
                print("[_showAddDeviceDialog] MOCK_DATA_MODE: Serving mock MQTT devices.");
                Future.delayed(const Duration(milliseconds: 400)).then((_) {
                  if (dialogContext.mounted) {
                    setDialogState(() {
                      mqttDeviceIds = ['shellyplugus-newmock1', 'shellyplugus-newmock2', 'shellyplugus-unregistered'].where((id) => !powerData.devices.any((d) => d['id'] == id)).toList();
                      _selectedMqttDeviceId = mqttDeviceIds.isNotEmpty ? mqttDeviceIds[0] : null;
                      isLoadingMqttDevices = false;
                    });
                  }
                });
              } else {
                 final token = Provider.of<AuthProvider>(dialogContext, listen: false).token;
                 if (token == null) {
                    setDialogState(() {
                       dialogError = "Authentication token not available.";
                       isLoadingMqttDevices = false;
                    });
                 } else {
                   ApiService.getAvailableMqttDevices(token).then((availableDevices) { // Use new method
                     if (dialogContext.mounted) {
                       setDialogState(() {
                         mqttDeviceIds = availableDevices // This list is from /api/mqtt-devices
                             .whereType<Map<String, dynamic>>()
                             .where((dMap) => dMap['id'] != null)
                             .map((dMap) => dMap['id'].toString())
                             .toList();
                         // The backend /api/mqtt-devices already ensures these are not registered.
                         if (mqttDeviceIds.isNotEmpty) {
                           _selectedMqttDeviceId = mqttDeviceIds[0];
                         }
                         isLoadingMqttDevices = false;
                       });
                     }
                   }).catchError((e) {
                     if (dialogContext.mounted) {
                       setDialogState(() {
                         dialogError = "Failed to load available devices: ${e.toString()}";
                         isLoadingMqttDevices = false;
                       });
                     }
                   });
                 }
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  top: 20,
                  left: 20,
                  right: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text("Add New Device",
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 16),
                  if (isLoadingMqttDevices)
                    const Center(child: Padding(padding: EdgeInsets.all(8.0), child: CircularProgressIndicator()))
                  else if (dialogError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(dialogError!, style: TextStyle(color: Theme.of(context).colorScheme.error), textAlign: TextAlign.center),
                    )
                  else if (mqttDeviceIds.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20.0),
                      child: Text("No new MQTT devices found to add.", textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                    )
                  else
                    DropdownButtonFormField<String>(
                      decoration: const InputDecoration(labelText: "Select Device ID from MQTT"),
                      value: _selectedMqttDeviceId,
                      items: mqttDeviceIds.map<DropdownMenuItem<String>>((String value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setDialogState(() {
                          _selectedMqttDeviceId = newValue;
                        });
                      },
                      dropdownColor: Theme.of(context).colorScheme.surface,
                    ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: "Enter Device Name"),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: (isLoadingMqttDevices || mqttDeviceIds.isEmpty || _selectedMqttDeviceId == null) ? null : () async {
                      String deviceName = _nameController.text.trim();
                      if (deviceName.isNotEmpty && _selectedMqttDeviceId != null) {
                        try {
                          final token = Provider.of<AuthProvider>(dialogContext, listen: false).token;
                          await powerData.addDevice(token, _selectedMqttDeviceId!, deviceName);
                          Navigator.pop(dialogContext);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Device "$deviceName" added!')),
                          );
                        } catch (e) {
                           ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Failed to add device: ${e.toString()}')),
                          );
                        }
                      } else {
                         ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please select a device ID and enter a name.')),
                          );
                      }
                    },
                    child: const Text("Add Device"),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          }
        );
      },
    );
  }

  Widget _buildDeviceCard(BuildContext context, String deviceName, String deviceId, bool status, Map<String, IconData> deviceIcons, PowerDataProvider powerData) {
    IconData deviceIcon = deviceIcons.entries.firstWhere((e) => deviceName.toLowerCase().contains(e.key.toLowerCase()), orElse: () => const MapEntry("", Icons.devices)).value;
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final token = Provider.of<AuthProvider>(context, listen: false).token;

    return Card(
      key: ValueKey('${deviceId}_$status'),
      elevation: Theme.of(context).cardTheme.elevation ?? 2,
      shape: Theme.of(context).cardTheme.shape,
      clipBehavior: Clip.antiAlias,
      child: Container( // Wrap content in Container for gradient
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, primaryAppBlue.withOpacity(0.7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12.0), // Match card border radius
        ),
        child: ListTile(
          visualDensity: VisualDensity.compact,
          leading: Icon(
            deviceIcon,
            size: 36,
            color: Colors.white, // Changed icon color for gradient
          ),
          title: Text(
            deviceName,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.white // Changed text color for gradient
            ),
          ),
          subtitle: Text(
            "ID: $deviceId",
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70 // Changed text color for gradient
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value: status,
                  onChanged: (bool newValue) async {
                    try {
                      await powerData.controlDevice(token, deviceId, newValue);
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to control $deviceName: ${e.toString()}'))
                      );
                    }
                  },
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                  color: Colors.redAccent[100]?.withOpacity(0.85)), // Changed icon color for gradient
                tooltip: 'Remove Device',
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (BuildContext dialogContext) {
                      return AlertDialog(
                        title: const Text('Remove Device'),
                        content: Text('Are you sure you want to remove "$deviceName"? This action cannot be undone.'),
                        actions: <Widget>[
                          TextButton(
                            child: const Text('Cancel'),
                            onPressed: () => Navigator.of(dialogContext).pop(false),
                          ),
                          TextButton(
                            child: Text('Remove', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                            onPressed: () => Navigator.of(dialogContext).pop(true),
                          ),
                        ],
                      );
                    },
                  );

                  if (confirm == true) {
                    try {
                      await powerData.removeDevice(token, deviceId);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"$deviceName" removed successfully.')));
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to remove "$deviceName": ${e.toString()}')));
                    }
                  }
                },
              ),
            ],
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => DeviceDetailPage(deviceId: deviceId, deviceName: deviceName),
              ),
            );
          },
        ),
      ),
    );
  }
}

class StatisticsPage extends StatefulWidget {
  @override
  _StatisticsPageState createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  String _selectedBreakdownPeriod = 'today'; // 'today', 'current_week', 'current_month'
  final Map<String, String> _breakdownPeriodLabels = {
    'today': 'Today',
    'current_week': 'This Week',
    'current_month': 'This Month',
  };

  // Controller for the PageView
  final PageController _pageController = PageController();
  // We no longer need _currentPage state as SmoothPageIndicator manages it internally
  // int _currentPage = 0;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final powerData = Provider.of<PowerDataProvider>(context, listen: false);
      if (authProvider.isAuth) {
        // Fetch all necessary statistics data if not already loading and data is missing
        if (!powerData.isLoading && (powerData.energyData.isEmpty || powerData.deviceConsumptionBreakdown.isEmpty || powerData.consumptionComparison.isEmpty)) {
          powerData.fetchHistoricalData(authProvider.token); // For 24hr chart (Wh)
          powerData.fetchDeviceConsumptionBreakdown(authProvider.token, _selectedBreakdownPeriod); // For pie chart (Wh)
          powerData.fetchConsumptionComparison(authProvider.token); // For comparison data (Wh)
        }
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose(); // Dispose the PageController
    super.dispose();
  }

  // Helper to calculate max Y value for charts, now handling kWh for display
  double _calculateMaxY(List<double> valuesKWh) {
    if (valuesKWh.isEmpty) return 1; // Default if no data for kWh
    double maxY = valuesKWh.reduce(max);
    return maxY > 0 ? maxY * 1.2 : 1; // Add 20% padding at the top, or default to 1 kWh if max is 0
  }

  // New method for building comparison chart cards, now using kWh for display
  Widget _buildComparisonChartCard(BuildContext context, String title, double currentValueKWh, double previousValueKWh, String currentLabel, String previousLabel) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    double maxY = _calculateMaxY([currentValueKWh, previousValueKWh]);

    return Card(
      elevation: Theme.of(context).cardTheme.elevation ?? 2,
      shape: Theme.of(context).cardTheme.shape,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black, primaryAppBlue.withOpacity(0.7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12.0),
        ),
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxY,
                  barTouchData: BarTouchData(
                    enabled: true,
                    touchTooltipData: BarTouchTooltipData(
                      tooltipBgColor: Theme.of(context).colorScheme.surface.withOpacity(0.9),
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        String label = rodIndex == 0 ? currentLabel : previousLabel;
                        return BarTooltipItem(
                          '$label\n',
                          TextStyle(
                            color: isDarkMode ? Colors.white : Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          children: <TextSpan>[
                            TextSpan(
                              text: '${rod.toY.toStringAsFixed(2)} kWh', // Display in kWh with 2 decimal places
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        getTitlesWidget: (value, meta) {
                          String text = '';
                          if (value == 0) {
                            text = currentLabel;
                          } else if (value == 1) {
                            text = previousLabel;
                          }
                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            space: 4.0,
                            child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70)),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) {
                          if (value == 0 && meta.max > 0) return SideTitleWidget(axisSide: meta.axisSide, child: const Text(''));
                          if (value == meta.max) return SideTitleWidget(axisSide: meta.axisSide, child: const Text(''));
                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            space: 8.0,
                            child: Text('${value.toStringAsFixed(1)} kWh', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70)), // Display kWh with 1 decimal
                          );
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: [
                    BarChartGroupData(
                      x: 0, // Represents current period
                      barRods: [
                        BarChartRodData(
                          toY: currentValueKWh, // Use kWh value
                          color: Theme.of(context).colorScheme.secondary, // Color for current
                          width: 25,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],
                    ),
                    BarChartGroupData(
                      x: 1, // Represents previous period
                      barRods: [
                        BarChartRodData(
                          toY: previousValueKWh, // Use kWh value
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.7), // Color for previous
                          width: 25,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],
                    ),
                  ],
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) {
                      return FlLine(color: Theme.of(context).dividerColor.withOpacity(0.5), strokeWidth: 0.5);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildLegendItem(context, Theme.of(context).colorScheme.secondary, currentLabel),
                _buildLegendItem(context, Theme.of(context).colorScheme.primary.withOpacity(0.7), previousLabel),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(BuildContext context, Color color, String text) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white)),
      ],
    );
  }


  @override
  Widget build(BuildContext context) {
    final powerData = Provider.of<PowerDataProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;


    if (powerData.isLoading && powerData.energyData.isEmpty && powerData.deviceConsumptionBreakdown.isEmpty && powerData.consumptionComparison.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
     if (powerData.error != null && powerData.energyData.isEmpty && powerData.deviceConsumptionBreakdown.isEmpty && powerData.consumptionComparison.isEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 50),
                const SizedBox(height: 10),
                Text('Error: ${powerData.error}', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 10),
                Text('Please check your backend server and network connection, then tap refresh in the app bar or pull down to refresh.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          )
        )
      );
    }

    return Scaffold(
      body: RefreshIndicator(
        color: Theme.of(context).colorScheme.secondary,
        backgroundColor: Theme.of(context).colorScheme.surface,
        onRefresh: () async {
          if (authProvider.isAuth) {
            await powerData.fetchHistoricalData(authProvider.token);
            await powerData.fetchDeviceConsumptionBreakdown(authProvider.token, _selectedBreakdownPeriod);
            await powerData.fetchConsumptionComparison(authProvider.token); // Fetch updated comparison data
          }
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Energy Insights', // Updated title
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 20),
              Text(
                'Overall Energy Consumption (Last 24 Hours)', // Clarified title
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 250,
                child: powerData.energyData.isEmpty && !powerData.isLoading
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40.0, horizontal: 20.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.bar_chart_outlined, size: 60, color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7)),
                            const SizedBox(height: 16),
                            Text("No Usage History", style: Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 8),
                            Text(
                              "Overall energy consumption data for the last 24 hours will appear here once available.",
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    )
                  : powerData.isLoading && powerData.energyData.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _buildStatisticBarChart(context, powerData.energyData), // Chart expects Wh, converts to kWh
              ),
              const SizedBox(height: 30),

              // --- Consumption Comparison Section (Swipeable Graphs) ---
              Text(
                'Consumption Comparison',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 250, // Fixed height for the PageView
                child: PageView(
                  controller: _pageController,
                  children: [
                    _buildComparisonChartCard(
                      context,
                      'Today vs Yesterday',
                      powerData.energyTodayKWh, // Pass kWh
                      powerData.energyYesterdayKWh, // Pass kWh
                      'Today',
                      'Yesterday',
                    ),
                    _buildComparisonChartCard(
                      context,
                      'This Week vs Last Week',
                      powerData.energyThisWeekKWh, // Pass kWh
                      powerData.energyLastWeekKWh, // Pass kWh
                      'This Week',
                      'Last Week',
                    ),
                    _buildComparisonChartCard(
                      context,
                      'This Month vs Last Month',
                      powerData.energyThisMonthKWh, // Pass kWh
                      powerData.energyLastMonthKWh, // Pass kWh
                      'This Month',
                      'Last Month',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: SmoothPageIndicator(
                  controller: _pageController,
                  count: 3, // Total number of comparison charts
                  effect: ExpandingDotsEffect(
                    activeDotColor: Theme.of(context).colorScheme.primary,
                    dotColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                    dotHeight: 8.0,
                    dotWidth: 8.0,
                    spacing: 4.0,
                  ),
                ),
              ),
              const SizedBox(height: 30),

              // --- Device Consumption Breakdown Section ---
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Device Consumption Breakdown',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  DropdownButton<String>(
                    value: _selectedBreakdownPeriod,
                    icon: const Icon(Icons.arrow_drop_down),
                    elevation: 16,
                    style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.bold),
                    underline: Container(height: 2, color: Theme.of(context).colorScheme.secondary.withOpacity(0.7)),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _selectedBreakdownPeriod = newValue;
                        });
                        if (authProvider.isAuth) {
                          powerData.fetchDeviceConsumptionBreakdown(authProvider.token, newValue);
                        }
                      }
                    },
                    items: _breakdownPeriodLabels.entries.map<DropdownMenuItem<String>>((MapEntry<String, String> entry) {
                      return DropdownMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value),
                      );
                    }).toList(),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 250, // Adjust height as needed for pie chart
                child: powerData.deviceConsumptionBreakdown.isEmpty && !powerData.isLoading
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40.0, horizontal: 20.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.pie_chart_outline, size: 60, color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7)),
                            const SizedBox(height: 16),
                            Text("No Breakdown Data", style: Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 8),
                            Text(
                              "Device consumption breakdown for '${_breakdownPeriodLabels[_selectedBreakdownPeriod]}' will appear here.",
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    )
                  : powerData.isLoading && powerData.deviceConsumptionBreakdown.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _buildDeviceBreakdownPieChart(context, powerData.deviceConsumptionBreakdown, _selectedBreakdownPeriod), // Chart expects Wh, converts to kWh
              ),
              const SizedBox(height: 10),
              // Optional: Ranked list for breakdown
              if (powerData.deviceConsumptionBreakdown.isNotEmpty)
                _buildRankedDeviceList(context, powerData.deviceConsumptionBreakdown), // List expects Wh, converts to kWh
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRankedDeviceList(BuildContext context, List<Map<String, dynamic>> breakdownData) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
          child: Text("Top Consuming Devices (${_breakdownPeriodLabels[_selectedBreakdownPeriod]})", style: Theme.of(context).textTheme.titleMedium),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: breakdownData.length,
          itemBuilder: (context, index) {
            final item = breakdownData[index];
            double consumedWh = (item['consumedWh'] as num?)?.toDouble() ?? 0.0;
            return Card(
              child: Container( // Wrap content in Container for gradient
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black, primaryAppBlue.withOpacity(0.7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12.0), // Match card border radius
                ),
                child: ListTile(
                  leading: CircleAvatar(child: Text("${index + 1}", style: TextStyle(color: Colors.white))), // Changed text color for gradient
                  title: Text(item['deviceName']?.toString() ?? 'Unknown', style: TextStyle(color: Colors.white)), // Changed text color for gradient
                  trailing: Text("${(consumedWh / 1000).toStringAsFixed(2)} kWh", style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.secondary)), // Display in kWh
                ),
              ),
            );
          },
        ),
      ],
    );
  }


  Widget _buildDeviceBreakdownPieChart(BuildContext context, List<Map<String, dynamic>> breakdownData, String period) {
    if (breakdownData.isEmpty) return Center(child: Text("No breakdown data.", style: Theme.of(context).textTheme.bodyMedium));

    double totalConsumptionWh = breakdownData.fold(0.0, (sum, item) => sum + ((item['consumedWh'] as num?)?.toDouble() ?? 0.0));
    double totalConsumptionKWh = totalConsumptionWh / 1000; // Convert to kWh for display
    if (totalConsumptionKWh == 0) return Center(child: Text("No consumption to display in breakdown.", style: Theme.of(context).textTheme.bodyMedium));

    // Define a list of colors for the pie chart segments
    final List<Color> pieColors = [
      Theme.of(context).colorScheme.primary,
      Theme.of(context).colorScheme.secondary,
      Colors.green.shade400,
      Colors.orange.shade400,
      Colors.purple.shade400,
      Colors.teal.shade400,
      Colors.redAccent.shade200,
      Colors.blueGrey.shade400,
      Colors.amber.shade400,
      Colors.indigo.shade400,
    ];

    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            sectionsSpace: 3, // Increased space between sections
            centerSpaceRadius: 60, // Increased to make it a donut chart
            sections: breakdownData.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              final double consumedWh = (item['consumedWh'] as num?)?.toDouble() ?? 0.0;
              final double consumedKWh = consumedWh / 1000; // Convert to kWh
              final double percentage = (consumedWh / totalConsumptionWh) * 100;
              return PieChartSectionData(
                color: pieColors[index % pieColors.length], // Cycle through colors
                value: consumedKWh, // Use kWh for value in pie chart
                title: '${percentage.toStringAsFixed(0)}%',
                radius: 80,
                titleStyle: TextStyle(
                  fontSize: 14, // Adjusted font size for readability
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onPrimary, // Ensure good contrast
                  shadows: [Shadow(color: Colors.black.withOpacity(0.5), blurRadius: 2)], // Add shadow for better visibility
                ),
                borderSide: const BorderSide(color: Colors.white, width: 2), // White border for separation
                titlePositionPercentageOffset: 0.6, // Adjusted position
              );
            }).toList(),
            pieTouchData: PieTouchData(
              touchCallback: (FlTouchEvent event, pieTouchResponse) {
                // Handle touch events if needed, e.g., to show more details
              },
            ),
          ),
        ),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Total',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${totalConsumptionKWh.toStringAsFixed(2)} kWh', // Display in kWh
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              _breakdownPeriodLabels[period]!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }


  // This chart is assumed to show HOURLY AGGREGATED ENERGY in Wh, converts to kWh for display
  Widget _buildStatisticBarChart(BuildContext context, List<Map<String, dynamic>> energyData) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    if (energyData.isEmpty) return Center(child: Text("No data for chart.", style: Theme.of(context).textTheme.bodyMedium));

    double maxYWh = 0;
    for (var dataPoint in energyData) {
      // Assuming 'energy' field contains hourly energy in Wh
      final energyVal = (dataPoint['energy'] as num?)?.toDouble() ?? 0.0;
      if (energyVal > maxYWh) {
        maxYWh = energyVal;
      }
    }
    // Provide a sensible default max Y if all values are 0, e.g., 100 Wh
    if (maxYWh == 0) maxYWh = 100;
    double maxYKWh = (maxYWh / 1000) * 1.2; // Convert to kWh and add some padding at the top

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxYKWh,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            tooltipBgColor: Theme.of(context).colorScheme.surface.withOpacity(0.9),
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              String hourLabel;
              try {
                 // Assuming data points are ordered by time, representing hourly intervals
                 final timestamp = DateTime.parse(energyData[group.x.toInt()]['timeStamp'] as String);
                 // Format as "HH:00"
                 hourLabel = '${timestamp.hour.toString().padLeft(2, '0')}:00';
              } catch(e){
                 hourLabel = 'Hour ${group.x.toInt()}'; // Fallback label
              }
              return BarTooltipItem(
                '$hourLabel\n',
                TextStyle(
                  color: isDarkMode ? Colors.white : Colors.black, // Adjust tooltip text color for dark/light mode
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                children: <TextSpan>[
                  TextSpan(
                    // Display energy in kWh, formatted to two decimal places
                    text: '${(rod.toY).toStringAsFixed(2)} kWh',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary, // Primary color for the value
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              );
            }
          )
        ),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 35,
              getTitlesWidget: (double value, TitleMeta meta) {
                final index = value.toInt();
                if (index >= 0 && index < energyData.length) {
                  try {
                    final timestamp = DateTime.parse(energyData[index]['timeStamp'] as String);
                    // Show labels every few hours to prevent clutter
                    if (energyData.length > 12 && index % (energyData.length ~/ 6).clamp(1, 4) != 0 && index != energyData.length -1 && index != 0) {
                       return SideTitleWidget(axisSide: meta.axisSide, child: const Text(''));
                    }
                     // Format as "HH:00"
                    return SideTitleWidget(axisSide: meta.axisSide, child: Text('${timestamp.hour.toString().padLeft(2, '0')}:00', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10, color: isDarkMode ? Colors.white70 : Colors.black54)));
                  } catch (e) {
                     return SideTitleWidget(axisSide: meta.axisSide, child: const Text('')); // Fallback
                  }
                }
                return SideTitleWidget(axisSide: meta.axisSide, child: const Text(''));
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40, // Give more space for kWh values
              getTitlesWidget: (value, meta) {
                 if (value == meta.max || (value == 0 && meta.max > 0)) return SideTitleWidget(axisSide: meta.axisSide, child: const Text('')); // Avoid clutter at 0 and max
                 // Display kWh values, formatted to one decimal place
                 return SideTitleWidget(
                   axisSide: meta.axisSide,
                   space: 8.0,
                   child: Text('${value.toStringAsFixed(1)} kWh', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10)),
                 );
              }
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        barGroups: energyData.asMap().entries.map((entry) {
          final index = entry.key;
          final dataPoint = entry.value;
          // Assuming 'energy' field contains hourly energy in Wh, convert to kWh
          final energyVal = (dataPoint['energy'] as num?)?.toDouble() ?? 0.0;
          return BarChartGroupData(
            x: index,
            barRods: [
              BarChartRodData(
                toY: energyVal / 1000, // Convert Wh to kWh
                color: Theme.of(context).colorScheme.primary,
                width: ((MediaQuery.of(context).size.width - 32 - 40 - (energyData.length * 2) ) / (energyData.length * 1.2)).clamp(2.0, 16.0),
                borderRadius: BorderRadius.circular(4)
              )
            ],
          );
        }).toList(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) {
            return FlLine(color: Theme.of(context).dividerColor.withOpacity(0.5), strokeWidth: 0.5);
          }
        )
      ),
    );
  }
}

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});
  @override
  _NotificationPageState createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final powerData = Provider.of<PowerDataProvider>(context, listen: false);
      // Fetch only if notifications are empty and not currently loading (globally or for notifications)
      if (authProvider.isAuth &&
          powerData.notifications.isEmpty &&
          !powerData.isLoading &&
          !powerData.isNotificationsLoading) {
        print("[NotificationPage] initState: Fetching notifications.");
        powerData.fetchNotifications(authProvider.token, reset: true, markLoadingGlobal: true);      }
    });
  }

  String _formatTimestamp(String? isoTimestamp) {
    if (isoTimestamp == null) return 'Unknown time';
    try {
      final dateTime = DateTime.parse(isoTimestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inMinutes < 1) {
        return 'Just now';
      } else if (difference.inMinutes < 60) {
        return '${difference.inMinutes}m ago';
      } else if (difference.inHours < 24) {
        return '${difference.inHours}h ago';
      } else if (difference.inDays < 7) {
        return '${difference.inDays}d ago';
      } else {
        return DateFormat('MMM d,yyyy').format(dateTime); // More readable format
      }
    } catch (e) {
      return 'Invalid date';
    }
  }

  IconData _getNotificationIcon(String? type) {
    // TODO: Implement your futuristic icons here
    switch (type) {
      case 'device_offline':
        return Icons.signal_wifi_off_outlined;
      case 'device_online':
        return Icons.signal_wifi_statusbar_4_bar_outlined;
      case 'high_power_spike_device': // Matches backend type
        return Icons.warning_amber_rounded;
      case 'goal_exceeded_system_daily': // Matches backend type
        return Icons.trending_up_outlined; // Or a goal/target icon
      case 'weekly_savings_achieved_system': // Matches backend type
        return Icons.celebration_outlined; // Or a star/trophy
      case 'system_message':
        return Icons.info_outline;
      default:
        return Icons.notifications_none;
    }
  }

 Color _getNotificationIconColor(String? severity, BuildContext context) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    switch (severity) {
      case 'warning':
        return Colors.orange.shade600;
      case 'critical':
        return Colors.redAccent.shade400;
      case 'info':
      default:
        return Colors.white; // Changed icon color for gradient
    }
  }

  @override
  Widget build(BuildContext context) {
    final powerData = Provider.of<PowerDataProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    // TODO: Add AppBar with "Mark all as read" button if desired
    // appBar: AppBar(
    //   title: Text("Notifications"),
    //   actions: [
    //     if (powerData.unreadNotificationCount > 0)
    //       TextButton(
    //         onPressed: () {
    //           if (authProvider.isAuth) {
    //             powerData.markAllNotificationsAsRead(authProvider.token);
    //           }
    //         },
    //         child: Text("Mark All Read", style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
    //       )
    //   ],
    // ),
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          print("[NotificationPage] Refresh triggered.");
          if (authProvider.isAuth) {
            await powerData.fetchNotifications(authProvider.token, reset: true, markLoadingGlobal: false);
          }
        },
        child: powerData.isNotificationsLoading && powerData.notifications.isEmpty
            ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
            : powerData.notificationsError != null && powerData.notifications.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 50),
                          const SizedBox(height: 10),
                          Text('Error: ${powerData.notificationsError}', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          const SizedBox(height: 10),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                            onPressed: () => powerData.fetchNotifications(authProvider.token, reset: true),
                          )
                        ],
                      ),
                    ))
                : powerData.notifications.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20.0), // Corrected to EdgeInsets.all(20.0)
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.notifications_off_outlined, size: 80, color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.6)),
                              const SizedBox(height: 20),
                              Text("No Notifications Yet", style: Theme.of(context).textTheme.headlineSmall),
                              const SizedBox(height: 10),
                              Text("Important updates and alerts about your devices will appear here.", textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: powerData.notifications.length,
                        itemBuilder: (context, index) {
                          final notification = powerData.notifications[index];
                          // Safely access fields with null checks and type casting
                          final bool isRead = notification['isRead'] as bool? ?? false;
                          final String message = notification['message'] as String? ?? 'No message content';
                          final String type = notification['type'] as String? ?? 'unknown';
                          final String severity = notification['severity'] as String? ?? 'info';
                          final String timestamp = notification['timestamp'] as String? ?? DateTime.now().toIso8601String();
                          final String id = notification['_id'] as String? ?? 'no-id-${DateTime.now().millisecondsSinceEpoch}';

                          // TODO: Apply futuristic styling to this Card and ListTile
                          return Card(
                            key: ValueKey(id), // Use a unique key
                            elevation: isRead ? 1.0 : 3.0,
                            color: Colors.transparent, // Set to transparent to show gradient
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              // side: BorderSide(color: isRead ? Colors.transparent : Theme.of(context).colorScheme.primary.withOpacity(0.5))
                            ),
                            child: Container( // Wrap content in Container for gradient
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [Colors.black, primaryAppBlue.withOpacity(0.7)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(12.0), // Match card border radius
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                leading: Icon(
                                  _getNotificationIcon(type),
                                  color: _getNotificationIconColor(severity, context),
                                  size: 30,
                                ),
                                title: Text(
                                  message,
                                  style: TextStyle(
                                    fontWeight: isRead ? FontWeight.normal : FontWeight.w600,
                                    fontSize: 14.5,
                                    color: Colors.white, // Changed text color for gradient
                                  ),
                                ),
                                subtitle: Text(
                                  _formatTimestamp(timestamp),
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5, color: Colors.white70), // Changed text color for gradient
                                ),
                                trailing: isRead
                                    ? null
                                    : Icon(Icons.circle, size: 10, color: Theme.of(context).colorScheme.secondary),
                                onTap: () async {
                                  if (!isRead && authProvider.isAuth) {
                                    await powerData.markNotificationAsRead(authProvider.token, id);
                                  }
                                  // TODO: Potentially navigate to a relevant page based on notification type/deviceId
                                  // e.g., if (notification['deviceId'] != null) { navigateToDevice(notification['deviceId']); }
                                },
                              ),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  final List<Map<String, dynamic>> settingsOptions = [
    {"icon": Icons.person_outline, "title": "Account"},
    {"icon": Icons.solar_power_outlined, "title": "Solar Details"},
    {"icon": Icons.contact_support_outlined, "title": "Contact Us"},
    {"icon": Icons.description_outlined, "title": "Terms & Conditions"},
    {"icon": Icons.privacy_tip_outlined, "title": "Privacy Policy"},
    {"icon": Icons.info_outline, "title": "About"},
    {"icon": Icons.logout, "title": "Logout"},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: settingsOptions.length + 1,
              separatorBuilder: (context, index) {
                if (index == 0) return const SizedBox.shrink();
                return Divider(height: 0.5, color: Theme.of(context).dividerColor.withOpacity(0.5), indent: 16, endIndent: 16);
              },
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20.0, top: 8.0),
                    child: Text(
                      "Settings",
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  );
                }

                final setting = settingsOptions[index - 1];
                final bool isDarkModeForSettings = Theme.of(context).brightness == Brightness.dark;
                return Card(
                   elevation: Theme.of(context).cardTheme.elevation ?? 2,
                   shape: Theme.of(context).cardTheme.shape,
                   clipBehavior: Clip.antiAlias,
                   color: Colors.transparent, // Set to transparent to show gradient
                   child: Container( // Wrap content in Container for gradient
                     decoration: BoxDecoration(
                       gradient: LinearGradient(
                         colors: [Colors.black, primaryAppBlue.withOpacity(0.7)],
                         begin: Alignment.topLeft,
                         end: Alignment.bottomRight,
                       ),
                       borderRadius: BorderRadius.circular(12.0), // Match card border radius
                     ),
                     child: ListTile(
                       leading: Icon(setting["icon"], size: 28,
                        color: Colors.white), // Changed icon color for gradient
                       title: Text(setting["title"],
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white)), // Changed text color for gradient
                       trailing: const Icon(Icons.arrow_forward_ios, size: 18, color: Colors.white70),
                       onTap: () {
                         if (setting["title"] == "Account") {
                           Navigator.push(
                             context,
                             MaterialPageRoute(builder: (context) => AccountOptionsPage()),
                           );
                         } else if (setting["title"] == "Logout") {
                            showDialog(
                               context: context,
                               builder: (ctx) => AlertDialog(
                                     title: const Text('Logout'),
                                     content: const Text('Are you sure you want to logout?'),
                                     actions: <Widget>[
                                       TextButton(
                                         child: const Text('Cancel'),
                                         onPressed: () => Navigator.of(ctx).pop(),
                                       ),
                                       TextButton(
                                         child: Text('Logout', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                                         onPressed: () {
                                           Provider.of<AuthProvider>(context, listen: false).logout().then((_) {
                                             Navigator.of(ctx).pop();
                                           });
                                         },
                                       ),
                                     ],
                                   ));
                         } else {
                           ScaffoldMessenger.of(context).showSnackBar(
                             SnackBar(content: Text("${setting["title"]} tapped")),
                           );
                         }
                       },
                     ),
                   ),
                 );
               },
             ),
           ),
           Padding(
             padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
             child: Center(
               child: Image.asset(
                 Theme.of(context).brightness == Brightness.dark ? 'assets/images/1.png' : 'assets/images/2.png', // Ensure these assets exist and are in pubspec.yaml
                 height: 150,
                 fit: BoxFit.contain,
                 errorBuilder: (context, error, stackTrace) {
                   print("[SettingsPage] Error loading image: $error");
                   return Icon(Icons.broken_image, color: Colors.red, size: 50); // Fallback icon
                 },
               ),
             ),
           ),
         ],
       ),
     );
   }
 }

 class AccountOptionsPage extends StatelessWidget {
   @override
   Widget build(BuildContext context) {
     return Scaffold(
       appBar: AppBar(title: const Text("Account Options")),
       body: Padding(
         padding: const EdgeInsets.all(32.0),
         child: Column(
           crossAxisAlignment: CrossAxisAlignment.stretch,
           mainAxisAlignment: MainAxisAlignment.center,
           children: [
             ElevatedButton(
               child: const Text("Login"),
               onPressed: () {
                 Navigator.push(
                   context,
                   MaterialPageRoute(builder: (_) => LoginPage()),
                 );
               },
             ),
             const SizedBox(height: 20),
             ElevatedButton(
               style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.secondary.withOpacity(0.8)),
               child: const Text("Sign Up"),
               onPressed: () {
                 Navigator.push(
                   context,
                   MaterialPageRoute(builder: (_) => SignupPage()),
                 );
               },
             ),
           ],
         ),
       ),
     );
   }
 }

// --- LoginPage ---
class LoginPage extends StatelessWidget {
  final TextEditingController emailController = TextEditingController();

  LoginPage({super.key});
  final TextEditingController passwordController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    const Color currentPrimaryAppBlue = primaryAppBlue;
    final Color currentAppSurfaceColor = isDarkMode ? appSurfaceColor : Colors.white.withOpacity(0.8);

    return Scaffold(
      appBar: AppBar(title: const Text("Login")),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Define logo height here
              SizedBox(height: MediaQuery.of(context).size.height * 0.2), // Adjusted
              Hero(
                tag: 'app_logo',
                child: Image.asset(
                  isDarkMode ? 'assets/images/1.png' : 'assets/images/2.png', // Ensure these assets exist and are in pubspec.yaml
                  height: 150,
                  errorBuilder: (context, error, stackTrace) {
                    print("[LoginPage] Error loading image: $error");
                    return Icon(Icons.broken_image, color: Colors.red, size: 50); // Fallback icon
                  },
                ), // Added Hero
              ),
              const SizedBox(height: 40),
              Text("Welcome Back!", style: Theme.of(context).textTheme.headlineMedium),
              Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.black, currentPrimaryAppBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: TextField(
                  style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87),
                  controller: emailController,
                  decoration: InputDecoration(
                    labelText: "Email",
                    labelStyle: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black54),
                    hintStyle: TextStyle(color: isDarkMode ? Colors.white60 : Colors.black45),
                    filled: true, // Set to true to use fillColor
                    fillColor: currentAppSurfaceColor, // Fill color for the text field content
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: isDarkMode ? Colors.white24 : Colors.black12),
                      borderRadius: BorderRadius.circular(6.0),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: currentPrimaryAppBlue),
                      borderRadius: BorderRadius.circular(6.0),
                    ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                ),
                keyboardType: TextInputType.emailAddress,              ),            ),            const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(3.0),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.black, currentPrimaryAppBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: TextField(
                  style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87),
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: "Password",
                    labelStyle: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black54),
                    hintStyle: TextStyle(color: isDarkMode ? Colors.white60 : Colors.black45),
                    filled: true, // Set to true to use fillColor
                    fillColor: currentAppSurfaceColor, // Fill color for the text field content
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: isDarkMode ? Colors.white24 : Colors.black12),
                      borderRadius: BorderRadius.circular(6.0),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: currentPrimaryAppBlue),
                      borderRadius: BorderRadius.circular(6.0),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                  ),
                  obscureText: true,
                ),
              ),
              const SizedBox(height: 40),
              Consumer<AuthProvider>(
                builder: (ctx, auth, _) => ElevatedButton(
                  child: auth.isLoading
                      ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0)
                      : const Text("Login"),
                  onPressed: auth.isLoading
                      ? null
                      : () async {
                    try {
                      await auth.login(emailController.text, passwordController.text);
                    } catch (error) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Login Failed: ${error.toString()}")),
                      );
                    }
                  },
                ),
              ),
              TextButton(
                child: Text("Don't have an account? Sign Up", style: TextStyle(color: isDarkMode ? Colors.white.withOpacity(0.85) : primaryAppBlue)),
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (context) => SignupPage()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- SignupPage ---
class SignupPage extends StatelessWidget {
  final TextEditingController nameController = TextEditingController();

  SignupPage({super.key});
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    const Color currentPrimaryAppBlue = primaryAppBlue;
    const Color currentAppSurfaceColor = appSurfaceColor;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Sign Up"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                isDarkMode ? 'assets/images/1.png' : 'assets/images/2.png', //logo
                fit: BoxFit.contain,
                height: MediaQuery.of(context).size.height * 0.2,
                width: 200,
                errorBuilder: (context, error, stackTrace) {
                  print("[SignupPage] Error loading image: $error");
                  return Icon(Icons.broken_image, color: Colors.red, size: 50); // Fallback icon
                },
              ),
               const SizedBox(height: 30),
              Text("Welcome Back!",
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white)),
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.all(3.0),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.black, currentPrimaryAppBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: "Your Name",
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintStyle: const TextStyle(color: Colors.white70),
                    filled: true, // Set to true to use fillColor
                    fillColor: currentAppSurfaceColor, // Fill color for the text field content
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6.0),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                  ),
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(3.0),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.black, currentPrimaryAppBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: TextField(
                  controller: emailController,
                  decoration: InputDecoration(
                    labelText: "Email",
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintStyle: const TextStyle(color: Colors.white70),
                    filled: true, // Set to true to use fillColor
                    fillColor: currentAppSurfaceColor, // Fill color for the text field content
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6.0),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(3.0),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.black, currentPrimaryAppBlue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: TextField(
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: "Password",
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintStyle: const TextStyle(color: Colors.white70),
                    filled: true, // Set to true to use fillColor
                    fillColor: currentAppSurfaceColor, // Fill color for the text field content
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6.0),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                  ),
                  obscureText: true,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
                ),
              ),
              const SizedBox(height: 30),
              Consumer<AuthProvider>(
                builder: (ctx, auth, _) => ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.secondary.withOpacity(0.9)),
                  child: auth.isLoading
                      ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0)
                      : const Text("Sign Up"),
                  onPressed: auth.isLoading ? null : () async {
                try {
                      await auth.signup(emailController.text, passwordController.text, nameController.text);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Signup successful! Please login.")),
                      );
                      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginPage()));
                    } catch (error) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Signup Failed: ${error.toString()}")),
                      );
                    }
                  },
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.secondary),
                child: const Text("Already have an account? Login"),
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (context) => LoginPage()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}


 class DeviceDetailPage extends StatefulWidget {
   final String deviceId;
   final String deviceName;
   const DeviceDetailPage({super.key, required this.deviceId, required this.deviceName});

   @override
   _DeviceDetailPageState createState() => _DeviceDetailPageState();
 }

 class _DeviceDetailPageState extends State<DeviceDetailPage> {
   // All energy values below are assumed to be in Wh from the API,
   // and will be converted to kWh for display.
   Map<String, dynamic>? _deviceStats; // Assumed to contain todayConsumed, yesterdayConsumed, thisMonthConsumed in Wh
   List<dynamic>? _deviceDailyHistory; // Assumed to contain daily 'consumed' in Wh
   bool _isLoading = true;
   String? _error;
  double? _monthlyTargetWh; // Stored in Wh as it comes from API
  PowerDataProvider? _powerDataProvider;
  final TextEditingController _targetController = TextEditingController();
  final PageController _pageController = PageController(); // Add PageController for swipable charts


   @override
   void initState() {
     super.initState();
     _fetchDeviceData();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadMonthlyTargetFromProvider();
    });
   }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final powerDataProviderInstance = Provider.of<PowerDataProvider>(context);
    if (_powerDataProvider != powerDataProviderInstance) {
      _powerDataProvider?.removeListener(_handlePowerDataChange); // Remove old listener if any
      _powerDataProvider = powerDataProviderInstance;
      _powerDataProvider!.addListener(_handlePowerDataChange);
    }
  }

  Future<void> _refreshDeviceData() async {
    // This will be called by RefreshIndicator
    await _fetchDeviceData();
    await _loadMonthlyTargetFromProvider(); // Refresh target after data fetch
  }

  @override
  void dispose() {
    _targetController.dispose();
    _pageController.dispose(); // Dispose the PageController
    _powerDataProvider?.removeListener(_handlePowerDataChange); // Ensure listener is removed
    super.dispose();
  }


  // This handler will now only trigger a UI refresh if the relevant data changes
  void _handlePowerDataChange() {
    if (!mounted) return;
    // Check if the device list has changed (e.g., target updated)
    final device = _powerDataProvider!.devices.firstWhere(
      (d) => d['id'] == widget.deviceId,
      orElse: () => <String, dynamic>{},
    );
    final newTarget = (device['monthlyTargetWh'] as num?)?.toDouble();

    // Always update the state if the device's target is found,
    // even if it's numerically the same, to ensure the UI is refreshed.
    // This helps with potential floating point precision issues or
    // if the UI state was somehow out of sync.
    // Removed the "if newTarget != _monthlyTargetWh" condition here to force update
    print("[DeviceDetailPage] _handlePowerDataChange: Updating target from $_monthlyTargetWh to $newTarget.");
    setState(() {
      _monthlyTargetWh = newTarget; // Still storing in Wh
      _targetController.text = _monthlyTargetWh != null ? (_monthlyTargetWh! / 1000).toStringAsFixed(2) : '';
    });
  }

  // Modified to load target directly from the PowerDataProvider's `devices` list
  Future<void> _loadMonthlyTargetFromProvider() async {
    final powerData = Provider.of<PowerDataProvider>(context, listen: false);
    // Ensure devices are fetched. This is critical.
    if (powerData.devices.isEmpty) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      await powerData.fetchDevices(authProvider.token);
    }

    final device = powerData.devices.firstWhere(
            (d) => d['id'] == widget.deviceId,
        orElse: () => <String, dynamic>{}
    );

    if (!mounted) return;

    final newTarget = (device['monthlyTargetWh'] as num?)?.toDouble(); // Get target in Wh

    // Always update _monthlyTargetWh and _targetController.text to reflect the latest from provider
    // This ensures consistency even if the value is numerically the same but state was stale.
    setState(() {
      _monthlyTargetWh = newTarget;
      _targetController.text = _monthlyTargetWh != null ? (_monthlyTargetWh! / 1000).toStringAsFixed(2) : '';
    });
    print("[DeviceDetailPage] Loaded monthly target for ${widget.deviceName}: $_monthlyTargetWh Wh. Controller text: ${_targetController.text}");
  }

  Future<void> _saveMonthlyTarget(double targetKWh) async { // Now takes kWh as input
    final powerData = Provider.of<PowerDataProvider>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    final double targetWh = targetKWh * 1000; // Convert to Wh for backend storage

    print("[DeviceDetailPage] Attempting to save target: $targetKWh kWh ($targetWh Wh)");

    try {
      bool success = await powerData.updateDeviceMonthlyTarget(authProvider.token, widget.deviceId, targetWh); // Send Wh to backend

      if (mounted) {
        if (success) {
          print("[DeviceDetailPage] Monthly target API call successful. PowerDataProvider should have already re-fetched devices.");
          // _loadMonthlyTargetFromProvider() will be called by the listener
          // due to fetchDevices() in PowerDataProvider.updateDeviceMonthlyTarget().
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Monthly target saved successfully!')),
          );
        } else {
          print("[DeviceDetailPage] Monthly target API call failed. Reverting UI.");
          // If backend save failed, revert UI to the previous state by reloading from provider.
          await _loadMonthlyTargetFromProvider();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save monthly target: ${powerData.error ?? "Unknown error"}')),
          );
        }
      }
    } catch (e) {
      print("[DeviceDetailPage] Error during monthly target save: $e. Reverting UI.");
      if (mounted) {
        // Revert UI on network error
        await _loadMonthlyTargetFromProvider();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving monthly target: ${e.toString()}')),
        );
      }
    }
  }

  void _showSetTargetDialog() {
    // Convert stored Wh to kWh for display in the input field
    _targetController.text = _monthlyTargetWh != null ? (_monthlyTargetWh! / 1000).toStringAsFixed(2) : '';

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Set Monthly Target'),
          content: TextField( // Content for kWh
            controller: _targetController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Target kWh for this month', // Changed to kWh
              suffixText: 'kWh', // Changed to kWh
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              child: const Text('Save'),
              onPressed: () {
                final double? newTargetKWh = double.tryParse(_targetController.text);
                if (newTargetKWh != null && newTargetKWh >= 0) {
                  _saveMonthlyTarget(newTargetKWh); // Pass kWh to save
                  Navigator.of(dialogContext).pop();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter a valid non-negative number.')),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  // FIX 1: Re-add async and Future<void> to _fetchDeviceData
  Future<void> _fetchDeviceData({bool isBackgroundRefresh = false}) async {
    if (!isBackgroundRefresh) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final token = Provider.of<AuthProvider>(context, listen: false).token;
      if (PowerDataProvider.MOCK_DATA_MODE) {
        print("[DeviceDetailPage] MOCK_DATA_MODE: Serving mock device stats and history for ${widget.deviceId}.");
        await Future.delayed(const Duration(milliseconds: 700));
        if (mounted) {
          setState(() {
            _deviceStats = {
              'todayConsumed': Random().nextDouble() * 2500, // Mock Wh
              'yesterdayConsumed': Random().nextDouble() * 3000, // Mock Wh
              'thisMonthConsumed': Random().nextDouble() * 40000 + 10000, // Mock Wh
              'status': Random().nextBool(),
            };
            _deviceDailyHistory = List.generate(7, (index) => {
              'date': DateTime.now().subtract(Duration(days: 6 - index)).toIso8601String().split('T')[0],
              'consumed': (Random().nextDouble() * 1500 + 200).toDouble(), // Mock Wh
            });
            if (!isBackgroundRefresh) {
              _isLoading = false;
            }
          });
        }
      } else {
        if (token == null) throw Exception("Not authenticated for device details");
        // Assuming getDeviceStats returns todayConsumed, yesterdayConsumed, thisMonthConsumed in Wh for THIS device
        final stats = await ApiService.getDeviceStats(token, widget.deviceId);
        // Assuming getDeviceDailyHistory returns daily 'consumed' in Wh for THIS device
        final history = await ApiService.getDeviceDailyHistory(token, widget.deviceId, days: 7);
        if (mounted) {
          setState(() {
            _deviceStats = stats;
            _deviceDailyHistory = history;
            if (!isBackgroundRefresh) {
              _isLoading = false;
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          if (!isBackgroundRefresh) {
            _isLoading = false;
          }
        });
      }
      print("Error fetching device data for ${widget.deviceId}: $e");
    }
  }


   @override
   Widget build(BuildContext context) {
     double usedTodayWh = 0.0;
     double usedYesterdayWh = 0.0;

     // Get kWh values for display
     double usedTodayKWh = 0.0;
     double usedYesterdayKWh = 0.0;

     String todayYesterdayLabel = "Today: -- kWh, Yesterday: -- kWh";
     double totalForPieKWh = 0.0;


     if (!_isLoading && _error == null && _deviceStats != null) {
       usedTodayWh = (_deviceStats!['todayConsumed'] as num?)?.toDouble() ?? 0.0;
       usedYesterdayWh = (_deviceStats!['yesterdayConsumed'] as num?)?.toDouble() ?? 0.0;
       
       usedTodayKWh = usedTodayWh / 1000;
       usedYesterdayKWh = usedYesterdayWh / 1000;

       todayYesterdayLabel = "Today: ${usedTodayKWh.toStringAsFixed(2)} kWh, Yesterday: ${usedYesterdayKWh.toStringAsFixed(2)} kWh";
       totalForPieKWh = usedTodayKWh + usedYesterdayKWh;
     }

     return Scaffold(
       appBar: AppBar(
         title: Text('${widget.deviceName} Details'),
       ),
       body: RefreshIndicator( // Added RefreshIndicator
         onRefresh: _refreshDeviceData,
         child: Padding(
           padding: const EdgeInsets.all(16.0),
           child: _isLoading
               ? const Center(child: CircularProgressIndicator())
               : _error != null
                   ? Center(
                       child: Column(
                         mainAxisAlignment: MainAxisAlignment.center,
                         children: [
                           Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 40),
                           const SizedBox(height: 10),
                           Text("Failed to load device details.", style: TextStyle(color: Theme.of(context).colorScheme.error)),
                           const SizedBox(height: 5),
                           Text(_error!, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
                           const SizedBox(height: 10),
                           // FIX 1: Use an anonymous async function for onPressed
                           ElevatedButton(onPressed: () async { await _fetchDeviceData(); }, child: const Text("Retry"))
                         ],
                       ))
                   : SingleChildScrollView(
               physics: const AlwaysScrollableScrollPhysics(), // Ensure scroll works with RefreshIndicator
               child: Column(
               crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                 Text(
                   widget.deviceName,
                   style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                 ),
                 const SizedBox(height: 20),
                 // Combined Swipable Charts Section
                 SizedBox(
                   height: 320, // Increased height for the PageView to prevent clipping
                   child: PageView(
                     controller: _pageController,
                     children: [
                       // Today vs. Yesterday Pie Chart
                       Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Row(
                             mainAxisAlignment: MainAxisAlignment.spaceBetween,
                             children: [
                               Text(
                                 "Today vs. Yesterday",
                                 style: Theme.of(context).textTheme.titleLarge,
                               ),
                               Flexible(
                                 child: Text(
                                   todayYesterdayLabel,
                                   textAlign: TextAlign.right,
                                   style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.bold),
                                 ),
                               ),
                             ],
                           ),
                           const SizedBox(height: 15),
                           Expanded(
                             child: _buildTodayYesterdayPieChart(context, usedTodayKWh, usedYesterdayKWh, totalForPieKWh),
                           ),
                         ],
                       ),
                       // Monthly Target Pie Chart
                       Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Text(
                             'Monthly Consumption Goal',
                             style: Theme.of(context).textTheme.titleLarge,
                           ),
                           const SizedBox(height: 5),
                           Row(
                             mainAxisAlignment: MainAxisAlignment.spaceBetween,
                             children: [
                               Flexible(
                                 child: Text(
                                   _monthlyTargetWh != null
                                       ? 'Target: ${(_monthlyTargetWh! / 1000).toStringAsFixed(2)} kWh' // Display kWh
                                       : 'No target set for this month.',
                                   style: Theme.of(context).textTheme.titleMedium,
                                 ),
                               ),
                               IconButton(
                                 icon: Icon(Icons.edit_note, color: Theme.of(context).colorScheme.secondary),
                                 tooltip: 'Set or Edit Monthly Target',
                                 onPressed: _showSetTargetDialog,
                               ),
                             ],
                           ),
                           const SizedBox(height: 15),
                           if (_deviceStats != null && _monthlyTargetWh != null && _monthlyTargetWh! > 0)
                             Expanded(child: _buildMonthlyTargetPieChart(context))
                           else if (_deviceStats != null && (_monthlyTargetWh == null || _monthlyTargetWh! <= 0))
                             Expanded(
                               child: Center(
                                 child: Column(
                                   mainAxisAlignment: MainAxisAlignment.center,
                                   children: [
                                     Icon(Icons.set_meal_outlined, size: 50, color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7)),
                                     const SizedBox(height: 10),
                                     Text(
                                       _monthlyTargetWh == null ? 'Set a monthly target to see progress.' : 'Target must be > 0 kWh.', // Updated text
                                       textAlign: TextAlign.center,
                                       style: Theme.of(context).textTheme.bodyMedium,
                                     ),
                                     const SizedBox(height: 10),
                                     ElevatedButton.icon(
                                       icon: const Icon(Icons.edit_note),
                                       label: const Text('Set Target'),
                                       onPressed: _showSetTargetDialog,
                                     )
                                   ],
                                 ),
                               ),
                             )
                           else
                             const Expanded(child: Center(child: CircularProgressIndicator())),
                         ],
                       ),
                     ],
                   ),
                 ),
                 const SizedBox(height: 8),
                 Center(
                   child: SmoothPageIndicator(
                     controller: _pageController,
                     count: 2,
                     effect: ExpandingDotsEffect(
                       activeDotColor: Theme.of(context).colorScheme.primary,
                       dotColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                       dotHeight: 8.0,
                       dotWidth: 8.0,
                       spacing: 4.0,
                     ),
                   ),
                 ),
                 const SizedBox(height: 25),

                Text(
                   'Usage Trend (Last 7 Days)',
                    style: Theme.of(context).textTheme.titleLarge,
                 ),
                 const SizedBox(height: 10),
                 _deviceDailyHistory == null || _deviceDailyHistory!.isEmpty
                   ? SizedBox(height: 220, child: Center(child: Text("No usage trend data available.", style: Theme.of(context).textTheme.bodyMedium)))
                   : SizedBox(
                   height: 220,
                   child: LineChart(
                     LineChartData(
                       gridData: FlGridData(
                         show: true,
                         drawVerticalLine: false,
                         getDrawingHorizontalLine: (value) => FlLine(color: Theme.of(context).dividerColor.withOpacity(0.5), strokeWidth: 0.5),
                       ),
                       titlesData: FlTitlesData(
                         show: true,
                         bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (value, meta) {
                           final index = value.toInt();
                           if (index >= 0 && index < _deviceDailyHistory!.length) {
                             try {
                               final dateStr = _deviceDailyHistory![index]['date'] as String;
                               final date = DateTime.parse(dateStr);
                               if (_deviceDailyHistory!.length > 7 && index % 2 != 0 && index != _deviceDailyHistory!.length -1 ) {
                                  return SideTitleWidget(axisSide: meta.axisSide, child: const Text(''));
                               }
                               return Text('${date.day}/${date.month}', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10));
                             } catch(e) {
                               return Text('D${index + 1}', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10));
                             }
                           }
                           return const Text('');
                         }, interval: _deviceDailyHistory!.length > 7 ? 2 : 1, reservedSize: 22)),
                         leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (value, meta) {
                            if (value == 0 && meta.max == 0) return SideTitleWidget(axisSide: meta.axisSide, child: const Text(''));
                            if (value == meta.max || (value == 0 && meta.max > 0)) return const Text('');
                            return SideTitleWidget(
                              axisSide: meta.axisSide,
                              space: 8.0,
                              child: Text('${value.toStringAsFixed(1)} kWh', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10)),
                            );
                         })),
                         topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                         rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                       ),
                       borderData: FlBorderData(show: true, border: Border.all(color: Theme.of(context).dividerColor)),
                       minX: 0,
                       maxX: (_deviceDailyHistory!.length - 1).toDouble(),
                       minY: 0,
                       maxY: _getChartMaxY() / 1000,
                       lineBarsData: [
                         LineChartBarData(
                           isCurved: true,
                           color: Theme.of(context).colorScheme.primary,
                           barWidth: 3,
                           isStrokeCapRound: true,
                           dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(radius: 4, color: Theme.of(context).colorScheme.secondary, strokeWidth: 1, strokeColor: Theme.of(context).scaffoldBackgroundColor)),
                           belowBarData: BarAreaData(show: true, gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary.withOpacity(0.3), Theme.of(context).colorScheme.primary.withOpacity(0.0)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
                           spots: _getChartSpotsKWh(),
                         ),
                       ],
                       lineTouchData: LineTouchData(
                          touchTooltipData: LineTouchTooltipData(
                            tooltipBgColor: Theme.of(context).colorScheme.surface.withOpacity(0.9),
                            getTooltipItems: (List<LineBarSpot> touchedBarSpots) {
                              return touchedBarSpots.map((barSpot) {
                                final flSpot = barSpot;
                                if (flSpot.x.toInt() < 0 || flSpot.x.toInt() >= _deviceDailyHistory!.length) {
                                  return null;
                                }
                                final dateStr = _deviceDailyHistory![flSpot.x.toInt()]['date'] as String;
                                return LineTooltipItem(
                                  '${DateTime.parse(dateStr).day}/${DateTime.parse(dateStr).month}: ',
                                  Theme.of(context).textTheme.bodyMedium!.copyWith(
                                        color: Theme.of(context).colorScheme.onSurface,
                                        fontWeight: FontWeight.bold,
                                      ),
                                  children: [
                                    TextSpan(text: '${flSpot.y.toStringAsFixed(2)} kWh',
                                      style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.w500)),
                                  ],
                                );
                              }).toList();
                            },
                          ),
                        ),
                     ),
                   ),
                 ),
                 const SizedBox(height: 25),
                 _deviceStats == null
                   ? const Center(child: Text("Loading stats...", style: TextStyle(color: Colors.white70)))
                   : Row(
                       mainAxisAlignment: MainAxisAlignment.spaceAround,
                       children: [
                         _buildStatBox(context, "${usedTodayKWh.toStringAsFixed(2)} kWh", "Today"),
                         _buildStatBox(context, "${usedYesterdayKWh.toStringAsFixed(2)} kWh", "Yesterday"),
                         // FIX 2: Corrected the parentheses for this calculation and display
                         _buildStatBox(context, "${(((_deviceStats!['thisMonthConsumed'] as num?)?.toDouble() ?? 0.0) / 1000).toStringAsFixed(2)} kWh", "This month"),
                       ],
                     ),
                 const SizedBox(height: 20),
               ],
             ),
           ),
         ),
        ),
      );
    }

  Widget _buildMonthlyTargetPieChart(BuildContext context) {
    final double consumedThisMonthWh = (_deviceStats!['thisMonthConsumed'] as num?)?.toDouble() ?? 0.0;
    final double targetWh = _monthlyTargetWh!; // Target is stored in Wh

    final double consumedThisMonthKWh = consumedThisMonthWh / 1000;
    final double targetKWh = targetWh / 1000;

    double usedValueKWh = consumedThisMonthKWh;
    double remainingValueKWh = (targetKWh - consumedThisMonthKWh).clamp(0.0, targetKWh);

    String usedTitle = "${usedValueKWh.toStringAsFixed(2)} kWh\nUsed";
    Color usedColor = Theme.of(context).colorScheme.secondary;

    String remainingTitle = "${remainingValueKWh.toStringAsFixed(2)} kWh\nLeft";
    Color remainingColor = Theme.of(context).colorScheme.primary.withOpacity(0.7);

    if (consumedThisMonthKWh > targetKWh && targetKWh > 0) {
      usedTitle = "${usedValueKWh.toStringAsFixed(2)} kWh Used\n(${(consumedThisMonthKWh - targetKWh).toStringAsFixed(2)} kWh Over)";
      usedColor = Theme.of(context).colorScheme.error;
      remainingValueKWh = 0.001; // Small value to ensure pie renders
      remainingTitle = "Target Exceeded";
      remainingColor = Theme.of(context).colorScheme.surface.withOpacity(0.5);
    } else if (consumedThisMonthKWh == targetKWh && targetKWh > 0) {
      remainingTitle = "Target Met!";
    }


    List<PieChartSectionData> sections = [
      PieChartSectionData(
        color: usedColor,
        value: usedValueKWh, // Use kWh value
        title: usedTitle,
        radius: 70,
        titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
        titlePositionPercentageOffset: 0.55,
      ),
      PieChartSectionData(
        color: remainingColor,
        value: remainingValueKWh > 0 ? remainingValueKWh : 0.001, // Ensure value is positive for pie chart
        title: remainingTitle,
        radius: 70,
        titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
        titlePositionPercentageOffset: 0.55,
      ),
    ];

    if (targetKWh <= 0) {
        return const SizedBox(height: 220, child: Center(child: Text("Target must be positive.")));
    }

    return SizedBox(
      height: 220,
      child: PieChart(
        PieChartData(
          sectionsSpace: 3,
          centerSpaceRadius: 55,
          sections: sections,
        ),
      ),
    );
  }

  Widget _buildTodayYesterdayPieChart(BuildContext context, double usedTodayKWh, double usedYesterdayKWh, double totalForPieKWh) {
    String todayPieTitle;
    String yesterdayPieTitle;

    if (totalForPieKWh > 0) {
      todayPieTitle = "${usedTodayKWh.toStringAsFixed(2)} kWh\n(${(usedTodayKWh / totalForPieKWh * 100).toStringAsFixed(0)}%)";
      yesterdayPieTitle = "${usedYesterdayKWh.toStringAsFixed(2)} kWh\n(${(usedYesterdayKWh / totalForPieKWh * 100).toStringAsFixed(0)}%)";
    } else {
      todayPieTitle = "0 kWh\n(0%)";
      yesterdayPieTitle = "0 kWh\n(0%)";
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            sectionsSpace: 3, // Increased space between sections
            centerSpaceRadius: 60, // Increased to make it a donut chart
            sections: [
              if (totalForPieKWh <= 0)
                PieChartSectionData(
                  color: Theme.of(context).colorScheme.surface.withOpacity(0.7),
                  value: 100, // Placeholder value
                  title: 'No Data (kWh)',
                  radius: 60,
                  titleStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  borderSide: const BorderSide(color: Colors.white, width: 2),
                )
              else ...[
                PieChartSectionData(
                  color: Theme.of(context).colorScheme.secondary,
                  value: usedTodayKWh,
                  title: todayPieTitle,
                  radius: 65,
                  titleStyle: TextStyle(
                    fontSize: 14, // Adjusted font size for readability
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSecondary,
                    shadows: [Shadow(color: Colors.black.withOpacity(0.5), blurRadius: 2)],
                  ),
                  borderSide: const BorderSide(color: Colors.white, width: 2),
                  titlePositionPercentageOffset: 0.6,
                ),
                PieChartSectionData(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
                  value: usedYesterdayKWh,
                  title: yesterdayPieTitle,
                  radius: 65,
                  titleStyle: TextStyle(
                    fontSize: 14, // Adjusted font size for readability
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimary,
                    shadows: [Shadow(color: Colors.black.withOpacity(0.5), blurRadius: 2)],
                  ),
                  borderSide: const BorderSide(color: Colors.white, width: 2),
                  titlePositionPercentageOffset: 0.6,
                ),
              ],
            ],
            pieTouchData: PieTouchData(
              touchCallback: (FlTouchEvent event, pieTouchResponse) {
                // Handle touch events if needed
              },
            ),
          ),
        ),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Total',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${totalForPieKWh.toStringAsFixed(2)} kWh', // Display in kWh
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Consumed',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }


   List<FlSpot> _getChartSpotsKWh() { // New method name to signify kWh output
     if (_deviceDailyHistory == null || _deviceDailyHistory!.isEmpty) {
       return [const FlSpot(0,0)];
     }
     return _deviceDailyHistory!.asMap().entries.map((entry) {
       int index = entry.key;
       // Assuming 'consumed' field contains daily energy in Wh, convert to kWh
       double consumedWh = (entry.value['consumed'] as num?)?.toDouble() ?? 0.0;
       return FlSpot(index.toDouble(), consumedWh / 1000); // Convert to kWh
     }).toList();
   }

   double _getChartMaxY() {
     if (_deviceDailyHistory == null || _deviceDailyHistory!.isEmpty) {
       return 100; // Default if no history, e.g., 100 Wh (for internal calculation before KWh conversion)
     }
     double maxYWh = 0;
     if (_deviceDailyHistory!.isNotEmpty) {
       // Assuming 'consumed' field contains daily energy in Wh
       maxYWh = _deviceDailyHistory!.map((item) => (item['consumed'] as num?)?.toDouble() ?? 0.0).reduce((a, b) => a > b ? a : b);
     }
     return maxYWh > 0 ? maxYWh * 1.2 : 100; // Return in Wh, will be converted to kWh at usage site
   }

   Widget _buildStatBox(BuildContext context, String value, String label) {
     final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
     return Expanded(
       child: Card(
         elevation: Theme.of(context).cardTheme.elevation ?? 2,
         shape: Theme.of(context).cardTheme.shape,
         clipBehavior: Clip.antiAlias,
         color: Colors.transparent, // Set to transparent to show gradient
         child: Container( // Wrap content in Container for gradient
           decoration: BoxDecoration(
             gradient: LinearGradient(
               colors: [Colors.black, primaryAppBlue.withOpacity(0.7)],
               begin: Alignment.topLeft,
               end: Alignment.bottomRight,
             ),
             borderRadius: BorderRadius.circular(12.0), // Match card border radius
           ),
           child: Padding(
             padding: const EdgeInsets.all(12.0),
             child: Column(
               mainAxisSize: MainAxisSize.min,
               children: [
                 Text(
                   value, // Value is already formatted in kWh
                   style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white, // Changed text color for gradient
                    fontWeight: FontWeight.bold),
                   textAlign: TextAlign.center,
                 ),
                 const SizedBox(height: 4),
                 Text(
                   label,
                   textAlign: TextAlign.center,
                   style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70 // Changed text color for gradient
                   ),
                 ),
               ],
             ),
           ),
         ),
       ),
     );
   }
 }
