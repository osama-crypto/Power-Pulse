import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:animations/animations.dart';
import 'auth_provider.dart';
import 'main.dart'; // For accessing primaryAppBlue, appSurfaceColor, etc.

class AuthPage extends StatefulWidget {
  const AuthPage({Key? key}) : super(key: key); // Add this constructor

  @override
  _AuthPageState createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool _showLogin = true;

  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController nameController = TextEditingController();

  void _toggleForm() {
    setState(() {
      _showLogin = !_showLogin;
      // Clear text fields when switching forms for better UX
      emailController.clear();
      passwordController.clear();
      nameController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
         decoration: BoxDecoration(
           color: isDarkMode ? appDarkBackground : Colors.grey[200],
         ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  isDarkMode ? 'assets/images/1.png' : 'assets/images/2.png',
                  height: MediaQuery.of(context).size.height * 0.25,
                  fit: BoxFit.contain,
                ),
                SizedBox(height: 30),
                PageTransitionSwitcher(
                  duration: const Duration(milliseconds: 600),
                  reverse: false, // Consistently transition in one direction
                  transitionBuilder: (
                    Widget child,
                    Animation<double> primaryAnimation,
                    Animation<double> secondaryAnimation,
                  ) {
                    // Return child directly for an immediate switch between forms
                    return child;
                  },
                  child: _showLogin
                      ? _LoginFormContent(
                          key: ValueKey('loginForm'),
                          emailController: emailController,
                          passwordController: passwordController,
                          onSwitchToSignup: _toggleForm,
                        )
                      : _SignupFormContent(
                          key: ValueKey('signupForm'),
                          nameController: nameController,
                          emailController: emailController,
                          passwordController: passwordController,
                          onSwitchToLogin: _toggleForm,
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

class _LoginFormContent extends StatelessWidget {
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final VoidCallback onSwitchToSignup;

  const _LoginFormContent({
    Key? key,
    required this.emailController,
    required this.passwordController,
    required this.onSwitchToSignup,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("Welcome Back!", style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white)),
        SizedBox(height: 30),
        Container(
          padding: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, primaryAppBlue], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: TextField(
            controller: emailController,
            decoration: InputDecoration(
              labelText: "Email",
              labelStyle: TextStyle(color: Colors.white70), hintStyle: TextStyle(color: Colors.white70),
              filled: true, fillColor: appSurfaceColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.0), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
            ),
            keyboardType: TextInputType.emailAddress,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
          ),
        ),
        SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, primaryAppBlue], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: TextField(
            controller: passwordController,
            decoration: InputDecoration(
              labelText: "Password",
              labelStyle: TextStyle(color: Colors.white70), hintStyle: TextStyle(color: Colors.white70),
              filled: true, fillColor: appSurfaceColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.0), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
            ),
            obscureText: true,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
          ),
        ),
        SizedBox(height: 30),
        Consumer<AuthProvider>(
          builder: (ctx, auth, _) => ElevatedButton(
            child: auth.isLoading ? CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0) : Text("Login"),
            onPressed: auth.isLoading ? null : () async {
              try {
                await auth.login(emailController.text, passwordController.text);
              } catch (error) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Login Failed: ${error.toString()}")));
              }
            },
          ),
        ),
        TextButton(
          child: Text("Don't have an account? Sign Up", style: TextStyle(color: Colors.white.withOpacity(0.85))),
          onPressed: onSwitchToSignup,
        ),
      ],
    );
  }
}

class _SignupFormContent extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final VoidCallback onSwitchToLogin;

  const _SignupFormContent({
    Key? key,
    required this.nameController,
    required this.emailController,
    required this.passwordController,
    required this.onSwitchToLogin,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("Create Account", style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white)),
        SizedBox(height: 30),
        Container(
          padding: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, primaryAppBlue], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: TextField(
            controller: nameController,
            decoration: InputDecoration(
              labelText: "Full Name",
              labelStyle: TextStyle(color: Colors.white70), hintStyle: TextStyle(color: Colors.white70),
              filled: true, fillColor: appSurfaceColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.0), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
            ),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
          ),
        ),
        SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, primaryAppBlue], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: TextField(
            controller: emailController,
            decoration: InputDecoration(
              labelText: "Email",
              labelStyle: TextStyle(color: Colors.white70), hintStyle: TextStyle(color: Colors.white70),
              filled: true, fillColor: appSurfaceColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.0), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
            ),
            keyboardType: TextInputType.emailAddress,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
          ),
        ),
        SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.black, primaryAppBlue], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: TextField(
            controller: passwordController,
            decoration: InputDecoration(
              labelText: "Password",
              labelStyle: TextStyle(color: Colors.white70), hintStyle: TextStyle(color: Colors.white70),
              filled: true, fillColor: appSurfaceColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.0), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
            ),
            obscureText: true,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white),
          ),
        ),
        SizedBox(height: 30),
        Consumer<AuthProvider>(
          builder: (ctx, auth, _) => ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.secondary.withOpacity(0.9)),
            child: auth.isLoading ? CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0) : Text("Sign Up"),
            onPressed: auth.isLoading ? null : () async {
              try {
                await auth.signup(emailController.text, passwordController.text, nameController.text);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Signup successful! Please login.")));
                onSwitchToLogin();
              } catch (error) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Signup Failed: ${error.toString()}")));
              }
            },
          ),
        ),
        TextButton(
          child: Text("Already have an account? Login", style: TextStyle(color: Colors.white.withOpacity(0.85))),
          onPressed: onSwitchToLogin,
        ),
      ],
    );
  }
}