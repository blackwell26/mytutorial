import { TestBed, ComponentFixture } from '@angular/core/testing';
import { GradesComponent } from './grades.component';
import { GradeService } from '../../services/grade.service';
import { Grade } from '../../models/grade.model';
import { HttpErrorResponse } from '@angular/common/http';
import { of, throwError } from 'rxjs';
import { describe, beforeEach, it, expect, vi } from 'vitest';

describe('GradesComponent', () => {
  let component: GradesComponent;
  let fixture: ComponentFixture<GradesComponent>;
  let gradeServiceSpy: { getGrades: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    gradeServiceSpy = {
      getGrades: vi.fn()
    };

    TestBed.configureTestingModule({
      imports: [GradesComponent],
      providers: [
        { provide: GradeService, useValue: gradeServiceSpy }
      ]
    });
  });

  it('should load grades on init', () => {
    const mockGrades: Grade[] = [
      { gradeId: 1, gradeNumber: 10, gradeName: 'A' }
    ];
    gradeServiceSpy.getGrades.mockReturnValue(of(mockGrades));

    fixture = TestBed.createComponent(GradesComponent);
    component = fixture.componentInstance;
    fixture.detectChanges(); // triggers ngOnInit

    expect(gradeServiceSpy.getGrades).toHaveBeenCalled();
    expect(component.grades()).toEqual(mockGrades);
    expect(component.loading()).toBe(false);
    expect(component.error()).toBe('');
  });

  it('should handle unauthorized error (401)', () => {
    const errorResponse = new HttpErrorResponse({
      status: 401,
      statusText: 'Unauthorized'
    });
    gradeServiceSpy.getGrades.mockReturnValue(throwError(() => errorResponse));

    fixture = TestBed.createComponent(GradesComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(component.error()).toBe('Session expired or unauthorised. Please sign in again.');
    expect(component.loading()).toBe(false);
  });

  it('should handle server unreachable error (0)', () => {
    const errorResponse = new HttpErrorResponse({
      status: 0,
      statusText: 'Unknown Error'
    });
    gradeServiceSpy.getGrades.mockReturnValue(throwError(() => errorResponse));

    fixture = TestBed.createComponent(GradesComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(component.error()).toBe('Cannot reach the server. Check that the backend is running and CORS is configured.');
    expect(component.loading()).toBe(false);
  });
});
