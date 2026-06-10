import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { Router } from '@angular/router';
import { AuthService } from './auth.service';
import { SignInRequest, SignUpRequest, AuthResponse } from '../models/auth.model';
import { describe, beforeEach, afterEach, it, expect, vi } from 'vitest';

describe('AuthService', () => {
  let service: AuthService;
  let httpMock: HttpTestingController;
  let routerSpy: { navigate: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    routerSpy = { navigate: vi.fn() };

    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        AuthService,
        { provide: Router, useValue: routerSpy }
      ]
    });

    service = TestBed.inject(AuthService);
    httpMock = TestBed.inject(HttpTestingController);

    // Clear localStorage before each test
    localStorage.clear();
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
  });

  it('should be created', () => {
    expect(service).toBeDefined();
  });

  it('should sign in and persist credentials', () => {
    const payload: SignInRequest = { username: 'testuser', password: 'password' };
    const mockResponse: AuthResponse = {
      token: 'mock-jwt-token',
      type: 'Bearer',
      username: 'testuser',
      email: 'testuser@example.com',
      roles: ['student']
    };

    service.signIn(payload).subscribe((res) => {
      expect(res).toEqual(mockResponse);
      expect(service.getToken()).toBe('mock-jwt-token');
      expect(service.isLoggedIn()).toBe(true);
      expect(service.currentUser).toEqual(mockResponse);
    });

    const req = httpMock.expectOne('http://localhost:8080/api/signin');
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual(payload);
    req.flush(mockResponse);
  });

  it('should sign up and persist credentials', () => {
    const payload: SignUpRequest = { username: 'newuser', email: 'new@example.com', password: 'password' };
    const mockResponse: AuthResponse = {
      token: 'mock-jwt-token',
      type: 'Bearer',
      username: 'newuser',
      email: 'new@example.com',
      roles: ['student']
    };

    service.signUp(payload).subscribe((res) => {
      expect(res).toEqual(mockResponse);
      expect(service.getToken()).toBe('mock-jwt-token');
      expect(service.isLoggedIn()).toBe(true);
    });

    const req = httpMock.expectOne('http://localhost:8080/api/signup');
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual(payload);
    req.flush(mockResponse);
  });

  it('should sign out and clear localStorage', () => {
    localStorage.setItem('auth_token', 'token');
    localStorage.setItem('auth_user', JSON.stringify({ username: 'test' }));

    service.signOut();

    expect(localStorage.getItem('auth_token')).toBeNull();
    expect(localStorage.getItem('auth_user')).toBeNull();
    expect(service.currentUser).toBeNull();
    expect(routerSpy.navigate).toHaveBeenCalledWith(['/auth']);
  });
});
