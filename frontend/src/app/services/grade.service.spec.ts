import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { GradeService } from './grade.service';
import { Grade } from '../models/grade.model';
import { describe, beforeEach, afterEach, it, expect } from 'vitest';

describe('GradeService', () => {
  let service: GradeService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [GradeService]
    });
    service = TestBed.inject(GradeService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('should be created', () => {
    expect(service).toBeDefined();
  });

  it('should fetch grades via GET request', () => {
    const mockGrades: Grade[] = [
      { gradeId: 1, gradeNumber: 10, gradeName: 'A' },
      { gradeId: 2, gradeNumber: 11, gradeName: 'B' }
    ];

    service.getGrades().subscribe((grades) => {
      expect(grades.length).toBe(2);
      expect(grades).toEqual(mockGrades);
    });

    const req = httpMock.expectOne('http://localhost:8080/api/grades');
    expect(req.request.method).toBe('GET');
    req.flush(mockGrades);
  });
});
