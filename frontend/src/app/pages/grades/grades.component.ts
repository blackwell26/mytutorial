import { Component, OnInit, signal } from '@angular/core';
import { GradeService } from '../../services/grade.service';
import { Grade } from '../../models/grade.model';
import { HttpErrorResponse } from '@angular/common/http';

@Component({
  selector: 'app-grades',
  standalone: true,
  imports: [],
  templateUrl: './grades.component.html',
  styleUrls: ['./grades.component.scss']
})
export class GradesComponent implements OnInit {
  grades  = signal<Grade[]>([]);
  loading = signal(true);
  error   = signal('');

  constructor(private gradeService: GradeService) {}

  ngOnInit(): void {
    this.gradeService.getGrades().subscribe({
      next: data => {
        this.grades.set(data);
        this.loading.set(false);
      },
      error: (err: HttpErrorResponse) => {
        // Log full error so the browser console shows the real cause
        console.error('[GradesComponent] HTTP error:', err.status, err.statusText, err);

        const message = this.extractErrorMessage(err);
        this.error.set(message);
        this.loading.set(false);
      }
    });
  }

  private extractErrorMessage(err: HttpErrorResponse): string {
    // CORS or network failure — status 0, no response body
    if (err.status === 0) {
      return 'Cannot reach the server. Check that the backend is running and CORS is configured.';
    }

    // 401 — token missing or invalid
    if (err.status === 401) {
      return 'Session expired or unauthorised. Please sign in again.';
    }

    // 403 — authenticated but not authorised
    if (err.status === 403) {
      return 'You do not have permission to view grades.';
    }

    // 404 — route not found
    if (err.status === 404) {
      return 'Grades endpoint not found (404). Check the API gateway routing.';
    }

    // Backend returned a JSON error body { "error": "..." }
    if (err.error && typeof err.error === 'object' && err.error['error']) {
      return err.error['error'];
    }

    // Backend returned a plain string body
    if (err.error && typeof err.error === 'string' && err.error.trim().length > 0) {
      return err.error;
    }

    // Generic fallback with status code
    return `Failed to load grades (HTTP ${err.status}: ${err.statusText}).`;
  }
}
