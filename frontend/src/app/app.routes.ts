import { Routes } from '@angular/router';
import { authGuard } from './guards/auth.guard';

export const routes: Routes = [
  // Default redirect
  { path: '', redirectTo: 'auth', pathMatch: 'full' },

  // Auth page (sign-in / sign-up)
  {
    path: 'auth',
    loadComponent: () =>
      import('./pages/auth/auth.component').then(m => m.AuthComponent)
  },

  // Protected dashboard shell
  {
    path: 'dashboard',
    loadComponent: () =>
      import('./pages/dashboard/dashboard.component').then(m => m.DashboardComponent),
    canActivate: [authGuard],
    children: [
      // Default child redirect
      { path: '', redirectTo: 'grades', pathMatch: 'full' },

      // Grades list page
      {
        path: 'grades',
        loadComponent: () =>
          import('./pages/grades/grades.component').then(m => m.GradesComponent)
      }
    ]
  },

  // Catch-all
  { path: '**', redirectTo: 'auth' }
];
