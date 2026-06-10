import { Component, signal } from '@angular/core';
import { RouterModule } from '@angular/router';
import { AuthService } from '../../services/auth.service';
import { AuthResponse } from '../../models/auth.model';

interface NavItem {
  label: string;
  icon: string;
  route: string;
}

@Component({
  selector: 'app-dashboard',
  standalone: true,
  imports: [RouterModule],
  templateUrl: './dashboard.component.html',
  styleUrls: ['./dashboard.component.scss']
})
export class DashboardComponent {
  sidebarOpen = signal(true);
  year = new Date().getFullYear();

  navItems: NavItem[] = [
    { label: 'Grades', icon: '📊', route: '/dashboard/grades' },
  ];

  get currentUser(): AuthResponse | null {
    return this.authService.currentUser;
  }

  /** Safe avatar letter — falls back to '?' if username is absent or empty. */
  get avatarLetter(): string {
    const name = this.authService.currentUser?.username;
    return name && name.length > 0 ? name[0].toUpperCase() : '?';
  }

  constructor(private authService: AuthService) {}

  toggleSidebar(): void {
    this.sidebarOpen.update(open => !open);
  }

  signOut(): void {
    this.authService.signOut();
  }
}
