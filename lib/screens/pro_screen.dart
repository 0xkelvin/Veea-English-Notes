import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../providers/pro_provider.dart';

String practiceText(BuildContext context, String english, String vietnamese) =>
    Localizations.localeOf(context).languageCode == 'vi' ? vietnamese : english;

class ProScreen extends StatelessWidget {
  const ProScreen({super.key});

  static Future<void> open(BuildContext context) {
    final pro = context.read<ProProvider?>();
    if (pro != null) unawaited(pro.refresh());
    return Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => const ProScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final pro = context.watch<ProProvider?>();
    final price = pro?.price;
    final message = pro?.localizedMessage(
      vietnamese: Localizations.localeOf(context).languageCode == 'vi',
    );
    final title = practiceText(
      context,
      'Veea Pro Lifetime',
      'Veea Pro trọn đời',
    );
    final theme = Theme.of(context);
    final status = switch (pro) {
      final p? when p.hasLocalApple => practiceText(
        context,
        'Active · Apple purchase',
        'Đang hoạt động · Giao dịch Apple',
      ),
      final p? when p.hasLocalSandbox => practiceText(
        context,
        'Active on this device · Apple Sandbox',
        'Đang hoạt động trên thiết bị · Apple Sandbox',
      ),
      final p? when p.hasServerApple => practiceText(
        context,
        'Active · Veea account purchase',
        'Đang hoạt động · Giao dịch gắn với tài khoản Veea',
      ),
      final p? when p.hasManualPremium => practiceText(
        context,
        'Pro access from your Veea account',
        'Quyền Pro từ tài khoản Veea',
      ),
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (status != null) ...[
                  Text(status, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                ],
                Text(
                  practiceText(
                    context,
                    'Unlock more apps with your vocabulary',
                    'Mở khóa nhiều ứng dụng bằng vốn từ của bạn',
                  ),
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  practiceText(
                    context,
                    'Free includes your learning features, 1 app lock and 1 selected word per unlock. One Pro purchase enables multiple app locks and multiple selected words per unlock.',
                    'Miễn phí các tính năng học từ, khóa 1 ứng dụng và ôn 1 từ đã chọn mỗi lần mở khóa. Mua Pro một lần để khóa nhiều ứng dụng và ôn nhiều từ đã chọn mỗi lần mở khóa.',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  practiceText(
                    context,
                    'Notebook, dictionary, Listen, Review, Practice Rounds and custom lists stay free. All unlock times, turning locks off and removing apps stay free.',
                    'Sổ từ, từ điển, Nghe, Ôn tập, Lượt luyện tập và danh sách tùy chọn luôn miễn phí. Mọi thời gian mở khóa, tắt khóa và xóa ứng dụng khỏi danh sách khóa đều miễn phí.',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  practiceText(
                    context,
                    'Pay once. No subscription or Veea account required.',
                    'Thanh toán một lần. Không cần đăng ký định kỳ hoặc tài khoản Veea.',
                  ),
                ),
                const SizedBox(height: 24),
                if (!AppConfig.isFreeLaunch && pro?.hasLifetime != true)
                  FilledButton(
                    key: const Key('buy_pro'),
                    onPressed: pro?.canPurchase == true ? pro!.purchase : null,
                    child: Text(
                      price == null
                          ? practiceText(
                              context,
                              'Purchase unavailable',
                              'Chưa thể mua',
                            )
                          : practiceText(
                              context,
                              'Get Pro · $price',
                              'Mua Pro · $price',
                            ),
                    ),
                  ),
                OutlinedButton(
                  key: const Key('restore_pro'),
                  onPressed: pro != null && !pro.isBusy ? pro.restore : null,
                  child: Text(
                    practiceText(
                      context,
                      'Restore Purchases',
                      'Khôi phục giao dịch',
                    ),
                  ),
                ),
                if (pro?.isBusy == true) const LinearProgressIndicator(),
                if (message != null)
                  Semantics(liveRegion: true, child: Text(message)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
