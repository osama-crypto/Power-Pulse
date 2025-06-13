import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api_service.dart';

class AuthProvider with ChangeNotifier {
  String? _token;
  Map<String, dynamic>? _user;
  DateTime? _expiryDate;
  Timer? _authTimer;

  final _storage = new FlutterSecureStorage();

  // isLoading state management
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  void _setLoading(bool loading) {
    if (_isLoading == loading) return; // Avoid unnecessary notifications
    _isLoading = loading;
    notifyListeners();
  }

  bool get isAuth {
    // Add token expiry check here if your backend provides it
    // For now, just check if token is not null
    return _token != null;
  }

  String? get token {
    // Add token expiry check here
    return _token;
  }

  Map<String, dynamic>? get user {
    return _user;
  }

  Future<void> _authenticateLogin(String email, String password) async {
    _setLoading(true);
    try {
      final responseData = await ApiService.loginUser(email, password);
      _token = responseData['token'] as String?;
      _user = responseData['user'] as Map<String, dynamic>?; // If backend sends user data
      // final expiresIn = responseData['expiresIn'] as int?; // If backend sends expiry
      // if (expiresIn != null) {
      //   _expiryDate = DateTime.now().add(Duration(seconds: expiresIn));
      //   _autoLogout();
      // }

      if (_token == null) {
        throw Exception('Authentication failed: No token received.');
      }

      final userData = json.encode({
        'token': _token,
        'user': _user, // Store the whole user object
        // 'userId': _user?['_id'], // Assuming your user object has an _id field
        // 'expiryDate': _expiryDate?.toIso8601String(),
      });
      await _storage.write(key: 'userData', value: userData);
      notifyListeners(); // Notify after successful login and token storage
    } catch (error) {
      print("Login error: $error");
      rethrow; // Rethrow to be caught by UI
    } finally {
      _setLoading(false); // Ensure loading is always turned off
    }
  }

  Future<void> signup(String email, String password, String name) async {
    _setLoading(true);
    try {
      // Directly call signupUser, which returns void
      await ApiService.signupUser(email, password, name);
      // Signup successful, user will need to login separately
      // No token is set here, no automatic login after signup in this flow
    } catch (error) {
      print("Signup error: $error");
      rethrow; // Rethrow to be caught by UI
    } finally {
      _setLoading(false); // Ensure loading is always turned off
    }
  }

  Future<void> login(String email, String password) async {
    return _authenticateLogin(email, password);
  }

  Future<bool> tryAutoLogin() async {
    final extractedUserData = await _storage.read(key: 'userData');
    if (extractedUserData == null) {
      return false;
    }
    final userData = json.decode(extractedUserData) as Map<String, dynamic>;

    // final expiryDateString = userData['expiryDate'] as String?;
    // if (expiryDateString != null) {
    //   final expiryDate = DateTime.parse(expiryDateString);
    //   if (expiryDate.isBefore(DateTime.now())) {
    //     await logout(); // Token expired
    //     return false;
    //   }
    //   _expiryDate = expiryDate;
    //   _autoLogout();
    // }
    _user = userData['user'] as Map<String, dynamic>?; // Retrieve the user object
    _token = userData['token'] as String?;
    // _user = {'id': userData['userId']}; // Reconstruct user if needed

    if (_token != null) {
      notifyListeners(); // Notify if auto-login is successful
      return true;
    }
    return false;
  }

  Future<void> logout() async {
    _token = null;
    _user = null;
    _expiryDate = null;
    if (_authTimer != null) {
      _authTimer!.cancel();
      _authTimer = null;
    }
    await _storage.delete(key: 'userData');
    notifyListeners();
  }

  // void _autoLogout() {
  //   if (_authTimer != null) {
  //     _authTimer!.cancel();
  //   }
  //   if (_expiryDate == null) return;
  //   final timeToExpiry = _expiryDate!.difference(DateTime.now()).inSeconds;
  //   if (timeToExpiry <= 0) {
  //     logout();
  //   } else {
  //     _authTimer = Timer(Duration(seconds: timeToExpiry), logout);
  //   }
  // }
}
