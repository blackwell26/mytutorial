import { Component, signal } from '@angular/core';
import { ReactiveFormsModule, FormBuilder, FormGroup, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { AuthService } from '../../services/auth.service';

type AuthTab = 'signin' | 'signup';

@Component({
  selector: 'app-auth',
  standalone: true,
  imports: [ReactiveFormsModule],   // no CommonModule needed with new control flow
  templateUrl: './auth.component.html',
  styleUrls: ['./auth.component.scss']
})
export class AuthComponent {
  // Signals — zoneless-safe reactive state
  activeTab = signal<AuthTab>('signin');
  loading   = signal(false);
  errorMsg  = signal('');

  signInForm: FormGroup;
  signUpForm: FormGroup;

  constructor(
    private fb: FormBuilder,
    private authService: AuthService,
    private router: Router
  ) {
    this.signInForm = this.fb.group({
      username: ['', [Validators.required]],
      password: ['', [Validators.required]]
    });

    this.signUpForm = this.fb.group({
      username: ['', [Validators.required, Validators.minLength(3)]],
      email:    ['', [Validators.required, Validators.email]],
      password: ['', [Validators.required, Validators.minLength(6)]]
    });
  }

  switchTab(tab: AuthTab): void {
    this.activeTab.set(tab);
    this.errorMsg.set('');
  }

  onSignIn(): void {
    if (this.signInForm.invalid) return;
    this.loading.set(true);
    this.errorMsg.set('');

    this.authService.signIn(this.signInForm.value).subscribe({
      next: () => this.router.navigate(['/dashboard']),
      error: err => {
        this.errorMsg.set(err.error?.error ?? 'Sign-in failed. Please try again.');
        this.loading.set(false);
      }
    });
  }

  onSignUp(): void {
    if (this.signUpForm.invalid) return;
    this.loading.set(true);
    this.errorMsg.set('');

    this.authService.signUp(this.signUpForm.value).subscribe({
      next: () => this.router.navigate(['/dashboard']),
      error: err => {
        this.errorMsg.set(err.error?.error ?? 'Sign-up failed. Please try again.');
        this.loading.set(false);
      }
    });
  }
}
