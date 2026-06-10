import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { Grade } from '../models/grade.model';

const API_BASE = 'http://localhost:8080';

@Injectable({ providedIn: 'root' })
export class GradeService {

  constructor(private http: HttpClient) {}

  getGrades(): Observable<Grade[]> {
    console.log('************************* getGrades');
    return this.http.get<Grade[]>(`${API_BASE}/api/grades`);
  }
}
