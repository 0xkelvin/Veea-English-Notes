import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../models/auth_models.dart';
import '../providers/auth_provider.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _onRegister() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await context.read<AuthProvider>().register(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
      // AuthProvider notifies → main.dart navigates to HomeScreen automatically
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Không thể kết nối đến máy chủ.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  _buildLogo(),
                  const SizedBox(height: 32),
                  _buildTitle(),
                  const SizedBox(height: 28),
                  _buildEmailField(),
                  const SizedBox(height: 14),
                  _buildPasswordField(),
                  const SizedBox(height: 14),
                  _buildConfirmField(),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 14),
                    _buildErrorBanner(),
                  ],
                  const SizedBox(height: 28),
                  _buildRegisterButton(),
                  const SizedBox(height: 24),
                  _buildLoginLink(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Center(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          gradient: AppColors.accentGradient,
          borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        ),
        child: const Icon(
          Icons.person_add_rounded,
          color: Colors.white,
          size: 30,
        ),
      ),
    );
  }

  Widget _buildTitle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Tạo tài khoản',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'Đăng ký để bắt đầu học từ vựng',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.mutedForeground,
              ),
        ),
      ],
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(
        labelText: 'Email',
        hintText: 'example@email.com',
        prefixIcon: Icon(Icons.email_outlined),
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Vui lòng nhập email';
        }
        final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
        if (!emailRegex.hasMatch(value.trim())) {
          return 'Email không hợp lệ';
        }
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      autofillHints: const [AutofillHints.newPassword],
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: 'Mật khẩu',
        hintText: '••••••••',
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(_obscurePassword
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined),
          onPressed: () =>
              setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) return 'Vui lòng nhập mật khẩu';
        if (value.length < 8) return 'Mật khẩu phải có ít nhất 8 ký tự';
        if (value.length > 128) return 'Mật khẩu quá dài';
        return null;
      },
    );
  }

  Widget _buildConfirmField() {
    return TextFormField(
      controller: _confirmController,
      obscureText: _obscureConfirm,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _onRegister(),
      decoration: InputDecoration(
        labelText: 'Xác nhận mật khẩu',
        hintText: '••••••••',
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(_obscureConfirm
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined),
          onPressed: () =>
              setState(() => _obscureConfirm = !_obscureConfirm),
        ),
      ),
      validator: (value) {
        if (value != _passwordController.text) {
          return 'Mật khẩu xác nhận không khớp';
        }
        return null;
      },
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.destructive.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
            color: AppColors.destructive.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline,
              color: AppColors.destructive, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.destructive,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegisterButton() {
    return SizedBox(
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.accentGradient,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        child: ElevatedButton(
          onPressed: _isLoading ? null : _onRegister,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : const Text(
                  'Đăng ký',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
        ),
      ),
    );
  }

  Widget _buildLoginLink() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Đã có tài khoản? ',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.mutedForeground,
              ),
        ),
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Text(
            'Đăng nhập',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );
  }
}
