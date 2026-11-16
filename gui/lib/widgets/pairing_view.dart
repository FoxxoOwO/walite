import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../bridge.dart';
import '../i18n.dart';
import '../theme.dart';

/// Authentic WhatsApp Web / Desktop pairing & connection screen:
/// supports QR scanning, phone-number pair code, connecting, syncing and retry.
class PairingView extends StatefulWidget {
  const PairingView({
    super.key,
    required this.snapshot,
    required this.bridge,
    required this.palette,
    required this.tr,
  });

  final Snapshot snapshot;
  final Bridge bridge;
  final WaPalette palette;
  final Tr tr;

  @override
  State<PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends State<PairingView> {
  final _phoneCtrl = TextEditingController();
  bool _showPhoneInput = false;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final tr = widget.tr;
    final p = widget.palette;

    return Container(
      color: p.chatCanvas,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 780),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.divider),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
          child: switch (s.connection) {
            'qr' => _buildQr(s, tr, p),
            'pair' => _buildPairCode(s, tr, p),
            'syncing' => _buildSyncing(s, tr),
            'error' => _buildError(s, tr),
            _ => _buildConnecting(tr),
          },
        ),
      ),
    );
  }

  Widget _buildQr(Snapshot s, Tr tr, WaPalette p) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'assets/icon.png',
                        width: 28,
                        height: 28,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.chat_bubble,
                          color: WaPalette.accentBright,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          tr.t('Přihlášení do WaLite', 'Log in to WaLite'),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: WaPalette.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    tr.t(
                      'Použij WhatsApp na počítači:',
                      'Use WhatsApp on your computer:',
                    ),
                    style: const TextStyle(
                      fontSize: 14,
                      color: WaPalette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _step('1', tr.t('Otevři WhatsApp v telefonu', 'Open WhatsApp on your phone')),
                  const SizedBox(height: 8),
                  _step('2', tr.t('Přejdi do Nastavení → Propojená zařízení', 'Go to Settings → Linked Devices')),
                  const SizedBox(height: 8),
                  _step('3', tr.t('Klepni na „Propojit zařízení“ a naskenuj QR kód', 'Tap "Link a Device" and scan the QR code')),
                  const SizedBox(height: 20),
                  TextButton.icon(
                    onPressed: () => setState(() => _showPhoneInput = !_showPhoneInput),
                    icon: const Icon(Icons.phonelink_lock, size: 18),
                    label: Text(
                      tr.t('Propojit pomocí telefonního čísla', 'Link with phone number'),
                    ),
                    style: TextButton.styleFrom(foregroundColor: WaPalette.accent),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 32),
            if (s.detail != null)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: QrImageView(
                  data: s.detail!,
                  size: 224,
                  backgroundColor: Colors.white,
                ),
              ),
          ],
        ),
        if (_showPhoneInput) ...[
          const SizedBox(height: 20),
          Divider(color: p.divider),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _phoneCtrl,
                  onSubmitted: (_) => _requestPairCode(),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: p.bg,
                    hintText: tr.t(
                      'Telefonní číslo s předvolbou (např. 420777123456)',
                      'Phone number with country code (e.g. 15551234567)',
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _requestPairCode,
                style: FilledButton.styleFrom(
                  backgroundColor: WaPalette.accent,
                  foregroundColor: Colors.black,
                ),
                child: Text(tr.t('Získat kód', 'Get Pair Code')),
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 14, color: WaPalette.textSecondary),
            const SizedBox(width: 6),
            Text(
              tr.t('Vaše osobní zprávy jsou šifrované end-to-end', 'Your personal messages are end-to-end encrypted'),
              style: const TextStyle(fontSize: 12, color: WaPalette.textSecondary),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPairCode(Snapshot s, Tr tr, WaPalette p) {
    final code = s.detail ?? '—';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr.t('Zadej tento kód v telefonu', 'Enter this code on your phone'),
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: WaPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          decoration: BoxDecoration(
            color: p.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: WaPalette.accent.withValues(alpha: 0.4)),
          ),
          child: SelectableText(
            code,
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.bold,
              letterSpacing: 6,
              color: WaPalette.accentBright,
            ),
          ),
        ),
        const SizedBox(height: 20),
        _step('1', tr.t('Otevři WhatsApp v telefonu', 'Open WhatsApp on your phone')),
        const SizedBox(height: 6),
        _step('2', tr.t('Nastavení → Propojená zařízení → Propojit zařízení', 'Settings → Linked Devices → Link a Device')),
        const SizedBox(height: 6),
        _step('3', tr.t('Klepni na „Propojit pomocí telefonního čísla“ a zadej kód', 'Tap "Link with phone number instead" and enter the code')),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: widget.bridge.cancelPairCode,
          child: Text(tr.t('Zrušit a vrátit se ke QR kódu', 'Cancel and return to QR')),
        ),
      ],
    );
  }

  Widget _buildSyncing(Snapshot s, Tr tr) {
    final pct = int.tryParse(s.detail ?? '') ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.sync, size: 42, color: WaPalette.accent),
        const SizedBox(height: 16),
        Text(
          tr.t('Dokončování přihlášení a synchronizace…', 'Finishing sign-in and syncing…'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 320,
          child: LinearProgressIndicator(
            value: pct > 0 ? (pct / 100).clamp(0.0, 1.0) : null,
            color: WaPalette.accent,
          ),
        ),
        const SizedBox(height: 12),
        if (pct > 0)
          Text('$pct %', style: const TextStyle(color: WaPalette.textSecondary)),
        const SizedBox(height: 12),
        TextButton(
          onPressed: widget.bridge.dismissSyncing,
          child: Text(tr.t('Pokračovat na pozadí', 'Continue in background')),
        ),
      ],
    );
  }

  Widget _buildError(Snapshot s, Tr tr) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 44, color: WaPalette.danger),
        const SizedBox(height: 14),
        Text(
          tr.t('Chyba připojení k WhatsApp', 'WhatsApp connection error'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          s.detail ?? '',
          textAlign: TextAlign.center,
          style: const TextStyle(color: WaPalette.textSecondary),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: widget.bridge.reconnectBackend,
          style: FilledButton.styleFrom(backgroundColor: WaPalette.accent),
          icon: const Icon(Icons.refresh),
          label: Text(tr.t('Zkusit znovu', 'Retry')),
        ),
      ],
    );
  }

  Widget _buildConnecting(Tr tr) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(color: WaPalette.accent),
        const SizedBox(height: 18),
        Text(
          tr.t('Připojování k WhatsApp…', 'Connecting to WhatsApp…'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          tr.t('Generuji QR kód, chvilku strpení…', 'Generating QR code, please wait…'),
          style: const TextStyle(color: WaPalette.textSecondary),
        ),
      ],
    );
  }

  Widget _step(String num, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: WaPalette.accent.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Text(
            num,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: WaPalette.accent,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontSize: 14, color: WaPalette.textPrimary),
          ),
        ),
      ],
    );
  }

  void _requestPairCode() {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) return;
    widget.bridge.requestPairCode(phone);
  }
}
