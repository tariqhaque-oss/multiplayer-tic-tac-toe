import 'package:flutter/material.dart';

import '../widgets/game_card.dart';
import 'connect4_screen.dart';
import 'court_piece_screen.dart';
import 'ludo_screen.dart';
import 'tic_tac_toe_screen.dart';

/// Full-page game picker for "Play Offline as Guest" - a dedicated page
/// rather than a bottom sheet, matching the logged-in GamesHubScreen's
/// grid layout so guest mode feels like the same app, not a different flow.
class GuestGamePickerScreen extends StatelessWidget {
  const GuestGamePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Play Offline as Guest')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'No account needed to play vs bots offline - log in or sign up '
                'later to save your results.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            Expanded(
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
                      MaterialPageRoute(builder: (_) => const TicTacToeScreen(guestMode: true)),
                    ),
                  ),
                  GameCard(
                    title: 'Connect Four',
                    icon: Icons.grid_4x4,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const Connect4Screen(guestMode: true)),
                    ),
                  ),
                  GameCard(
                    title: 'Ludo',
                    icon: Icons.casino,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LudoScreen(guestMode: true)),
                    ),
                  ),
                  GameCard(
                    title: 'Court Piece',
                    icon: Icons.style,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CourtPieceScreen(guestMode: true)),
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
}
