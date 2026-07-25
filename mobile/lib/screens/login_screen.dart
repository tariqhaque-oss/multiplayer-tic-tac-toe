import 'package:flutter/material.dart';

import '../api/api_client.dart';
import 'games_hub_screen.dart';
import 'guest_game_picker_screen.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _api = ApiClient();
  String? _error;
  bool _loading = false;

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _api.login(_emailController.text.trim(), _passwordController.text);
      if (!mounted) return;

      if (result.ok) {
        // Deliberately does NOT auto-claim any guest-mode games here - if
        // more than one account has ever used this device, silently
        // attributing guest games to whichever one just logged in would
        // guess wrong as often as right. Guest games stay queued under the
        // guest tag and get resolved explicitly via the Stats screen's
        // Sync Now flow instead, which always asks when there's a real
        // choice to make.
        if (!mounted) return;
        // Clears the whole navigation stack, not just this screen - if this
        // login was reached from a guest offline game's "Log In to Save"
        // button, that guest screen must not still be reachable via back
        // navigation once a real account is active.
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const GamesHubScreen()),
          (route) => false,
        );
      } else {
        setState(() => _error = _errorMessage(result.error));
      }
    } catch (_) {
      setState(() => _error = 'No connection. Check your internet and try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _errorMessage(String? code) {
    switch (code) {
      case 'invalid':
        return 'Incorrect email or password.';
      case 'unverified':
        return 'Please verify your email first (check your inbox).';
      default:
        return 'Login failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('GameHub', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 32),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
              const SizedBox(height: 20),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              ElevatedButton(
                onPressed: _loading ? null : _login,
                child: _loading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Log In'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SignupScreen()),
                ),
                child: const Text("Don't have an account? Sign Up"),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.wifi_off),
                label: const Text('Play Offline as Guest'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const GuestGamePickerScreen()),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'No account needed to play vs bots offline - log in or sign up '
                  'later to save your results.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
