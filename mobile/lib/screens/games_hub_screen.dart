import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../widgets/game_card.dart';
import 'connect4_screen.dart';
import 'court_piece_screen.dart';
import 'login_screen.dart';
import 'ludo_screen.dart';
import 'tic_tac_toe_screen.dart';

class GamesHubScreen extends StatelessWidget {
  const GamesHubScreen({super.key});

  Future<void> _handleLogout(BuildContext context) async {
    final stillPending = await ApiClient().logout();

    if (!context.mounted) return;

    if (stillPending > 0) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Offline games not synced'),
          content: Text(
            '$stillPending offline game${stillPending == 1 ? '' : 's'} could not be synced '
            '(no connection) and will be saved to whichever account logs in next and syncs. '
            'Log back in to this account before you\'re next online to make sure they count here.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
    }

    if (context.mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GameHub'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () => _handleLogout(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.85,
          children: [
            GameCard(
              title: 'Tic Tac Toe',
              icon: Icons.grid_3x3,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TicTacToeScreen()),
              ),
            ),
            GameCard(
              title: 'Connect Four',
              icon: Icons.grid_4x4,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const Connect4Screen()),
              ),
            ),
            GameCard(
              title: 'Ludo',
              icon: Icons.casino,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LudoScreen()),
              ),
            ),
            GameCard(
              title: 'Court Piece',
              icon: Icons.style,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CourtPieceScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
