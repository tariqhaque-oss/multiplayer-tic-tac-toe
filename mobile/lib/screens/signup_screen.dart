import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../main.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _emailController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _api = ApiClient();
  String? _error;
  String? _successMessage;
  bool _loading = false;

  Future<void> _signup() async {
    setState(() {
      _loading = true;
      _error = null;
      _successMessage = null;
    });

    try {
      final result = await _api.signup(
        _emailController.text.trim(),
        _nicknameController.text.trim(),
        _passwordController.text,
        _confirmController.text,
      );
      if (!mounted) return;

      if (result.ok) {
        setState(() {
          _successMessage = 'Account created! Check your email for a verification link, '
              'then come back and log in.';
        });
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
      case 'invalid_email':
        return 'Enter a valid email address.';
      case 'invalid_nickname':
        return 'Nickname must be 3-24 characters (letters, numbers, underscore).';
      case 'mismatch':
        return 'Passwords do not match.';
      case 'weak':
        return 'Password must be at least 8 characters.';
      case 'taken':
        return 'That email is already registered.';
      case 'nickname_taken':
        return 'That nickname is already taken.';
      default:
        return 'Signup failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign Up')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_successMessage != null) ...[
                Text(_successMessage!, style: TextStyle(color: context.successColor)),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back to Log In'),
                ),
              ] else ...[
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'Email'),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nicknameController,
                  decoration: const InputDecoration(labelText: 'Nickname'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmController,
                  decoration: const InputDecoration(labelText: 'Confirm Password'),
                  obscureText: true,
                ),
                const SizedBox(height: 20),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                ElevatedButton(
                  onPressed: _loading ? null : _signup,
                  child: _loading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Sign Up'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
