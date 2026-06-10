import { TestBed, ComponentFixture } from '@angular/core/testing';
import { ReactiveFormsModule, FormBuilder } from '@angular/forms';
import { Router } from '@angular/router';
import { AuthComponent } from './auth.component';
import { AuthService } from '../../services/auth.service';
import { of, throwError } from 'rxjs';
import { describe, beforeEach, it, expect, vi } from 'vitest';

describe('AuthComponent', () => {
  let component: AuthComponent;
  let fixture: ComponentFixture<AuthComponent>;
  let authServiceSpy: { signIn: ReturnType<typeof vi.fn>, signUp: ReturnType<typeof vi.fn> };
  let routerSpy: { navigate: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    authServiceSpy = {
      signIn: vi.fn(),
      signUp: vi.fn()
    };
    routerSpy = { navigate: vi.fn() };

    TestBed.configureTestingModule({
      imports: [ReactiveFormsModule, AuthComponent],
      providers: [
        FormBuilder,
        { provide: AuthService, useValue: authServiceSpy },
        { provide: Router, useValue: routerSpy }
      ]
    });

    fixture = TestBed.createComponent(AuthComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeDefined();
  });

  it('should initialize invalid forms by default', () => {
    expect(component.signInForm.invalid).toBe(true);
    expect(component.signUpForm.invalid).toBe(true);
  });

  it('should validate form fields correctly', () => {
    const usernameInput = component.signInForm.controls['username'];
    const passwordInput = component.signInForm.controls['password'];

    usernameInput.setValue('');
    passwordInput.setValue('');
    expect(component.signInForm.invalid).toBe(true);

    usernameInput.setValue('testuser');
    passwordInput.setValue('password');
    expect(component.signInForm.valid).toBe(true);
  });

  it('should switch tabs and reset error message', () => {
    component.errorMsg.set('Some error');
    component.switchTab('signup');
    expect(component.activeTab()).toBe('signup');
    expect(component.errorMsg()).toBe('');
  });

  it('should navigate to dashboard on successful sign-in', () => {
    component.signInForm.controls['username'].setValue('testuser');
    component.signInForm.controls['password'].setValue('password');
    authServiceSpy.signIn.mockReturnValue(of({}));

    component.onSignIn();

    expect(authServiceSpy.signIn).toHaveBeenCalledWith({ username: 'testuser', password: 'password' });
    expect(routerSpy.navigate).toHaveBeenCalledWith(['/dashboard']);
  });

  it('should set errorMsg on failed sign-in', () => {
    component.signInForm.controls['username'].setValue('testuser');
    component.signInForm.controls['password'].setValue('password');
    const mockError = { error: { error: 'Invalid credentials' } };
    authServiceSpy.signIn.mockReturnValue(throwError(() => mockError));

    component.onSignIn();

    expect(component.errorMsg()).toBe('Invalid credentials');
    expect(component.loading()).toBe(false);
  });
});
