import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart'; // Assuming HomePage is in main.dart

class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  // No timer needed here anymore, as MyApp's FutureBuilder handles navigation
  // based on the auto-login result.

  @override
  Widget build(BuildContext context) {
    // Get screen width to make the logo somewhat responsive
    double screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: Colors.white, // Ensure background is always white
      body: Center(
        child: Image.asset(
          'assets/images/2.png', // Always use img2.png
          width: screenWidth * 0.6, // Make logo 60% of screen width, adjust as needed
          fit: BoxFit.contain, // Ensures the whole logo is visible
        ),
      ),
    );
  }
}
