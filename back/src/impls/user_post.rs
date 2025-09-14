use actix_multipart::Multipart;
use actix_web::HttpResponse;
use futures::future::join_all;
use sqlx::MySqlPool;
use std::str;

use crate::filters::SelfassessableFilter;
use crate::parse_multipart::parse_multipart;
use crate::structs::*;
use crate::traits::{Get, Post};
use crate::send_grade_email;

impl Post for MySelf {
    async fn post_assessment(&self, pool: &MySqlPool, payload: Payload) -> HttpResponse {
        match self.role {
            Role::teacher => {
                let teacher_subject: bool = match sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM subjects WHERE teacher_id = ? AND id = ?)",
                )
                .bind(self.id)
                .bind(payload.newtask.subject)
                .fetch_one(pool)
                .await
                {
                    Ok(s) => s,
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
                };
                if !teacher_subject {
                    return HttpResponse::Unauthorized().finish();
                }
            }
            Role::admin => {}
            _ => return HttpResponse::Unauthorized().finish(),
        };

        if payload.newtask.type_ == AssessmentType::Selfassessable {
            let selfassessable = match &payload.newselfassessable {
                Some(a) => a,
                None => return HttpResponse::BadRequest().json("Missing selfassessable"),
            };

            if !(selfassessable.validate()) {
                return HttpResponse::BadRequest().json("Invalid selfassessable");
            }

            let insert_result = match sqlx::query(
                "INSERT INTO assessments (task, subject_id, type, due_date) VALUES (?, ?, ?, ?)",
            )
            .bind(&payload.newtask.task)
            .bind(payload.newtask.subject)
            .bind(&payload.newtask.type_)
            .bind(&payload.newtask.due_date)
            .execute(pool)
            .await
            {
                Ok(res) => res,
                Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
            };
            let assessment_id = insert_result.last_insert_id();

            let assessable =
                match sqlx::query("INSERT INTO selfassessables (assessment_id) VALUES (?)")
                    .bind(assessment_id)
                    .execute(pool)
                    .await
                {
                    Ok(r) => r,
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
                };

            let assessable_id = assessable.last_insert_id();
            let mut queries = selfassessable.generate_query(assessable_id);

            let results = join_all(queries.iter_mut().map(|q| q.build().execute(pool))).await;
            for res in results {
                match res {
                    Ok(_) => {}
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
                }
            }

            return HttpResponse::Created().finish();
        } else {
            let insert_result = sqlx::query(
                "INSERT INTO assessments (task, subject_id, type, due_date) VALUES (?, ?, ?, ?)",
            )
            .bind(&payload.newtask.task)
            .bind(payload.newtask.subject)
            .bind(&payload.newtask.type_)
            .bind(&payload.newtask.due_date)
            .execute(pool)
            .await;

            match insert_result {
                Ok(_) => {
                    // Enviar email a todos los estudiantes del curso de la materia
                    let students: Vec<(String, String, String)> = match sqlx::query_as::<_, (String, String, String)>(
                        r#"
                        SELECT u.email, pd.full_name, s.name
                        FROM users u
                        JOIN personal_data pd ON pd.user_id = u.id
                        JOIN subjects s ON s.course_id = u.course_id
                        WHERE s.id = ?
                        "#
                    )
                    .bind(payload.newtask.subject)
                    .fetch_all(pool)
                    .await
                    {
                        Ok(list) => list,
                        Err(_) => vec![],
                    };
                    let sender_name: String = match sqlx::query_scalar("SELECT full_name FROM personal_data WHERE user_id = ?")
                        .bind(self.id)
                        .fetch_one(pool)
                        .await
                    {
                        Ok(name) => name,
                        Err(_) => "Remitente".to_string(),
                    };
                    crate::email::send_assessment_email(
                        students,
                        &sender_name,
                        &payload.newtask.task,
                        &payload.newtask.due_date.to_string()
                    ).await;
                    HttpResponse::Created().finish()
                },
                Err(e) => HttpResponse::InternalServerError().json(e.to_string()),
            }
        }
    }
    async fn post_grade(&self, pool: &MySqlPool, grade: NewGrade) -> HttpResponse {
        match self.role {
            Role::admin => {}
            Role::teacher => {
                let teacher_subject: bool = match sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM subjects WHERE teacher_id = ? AND id = ?)",
                )
                .bind(self.id)
                .bind(grade.subject)
                .fetch_one(pool)
                .await
                {
                    Ok(s) => s,
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
                };
                if !teacher_subject {
                    return HttpResponse::Unauthorized().finish();
                }
            }
            _ => return HttpResponse::Unauthorized().finish(),
        };

        let course =
            match sqlx::query_scalar::<_, u64>("SELECT course_id FROM subjects WHERE id = ?")
                .bind(grade.subject)
                .fetch_one(pool)
                .await
            {
                Ok(c) => c,
                Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
            };

        let student_course: bool = match sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM users WHERE id = ? AND course_id = ?)",
        )
        .bind(grade.student_id)
        .bind(course)
        .fetch_one(pool)
        .await
        {
            Ok(s) => s,
            Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
        };
        if !student_course {
            return HttpResponse::Unauthorized().finish();
        }

        if let Some(assessment_id) = grade.assessment_id {
            let assessment_verify: bool = match sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM assessments WHERE id = ? AND subject_id = ?)",
            )
            .bind(assessment_id)
            .bind(grade.subject)
            .fetch_one(pool)
            .await
            {
                Ok(s) => s,
                Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
            };
            if !assessment_verify {
                return HttpResponse::Unauthorized().finish();
            }
            let assessment_already_exixts: bool = match sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM grades WHERE assessment_id = ? AND student_id = ? )",
            )
            .bind(assessment_id)
            .bind(grade.student_id)
            .fetch_one(pool)
            .await
            {
                Ok(s) => s,
                Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
            };
            if assessment_already_exixts {
                return HttpResponse::Unauthorized().finish();
            }
            let result = sqlx::query("INSERT INTO grades (assessment_id, student_id, grade_type, description, grade, subject_id) VALUES (?, ?, ?, ?, ?, ?)")
                .bind(assessment_id)
                .bind(grade.student_id)
                .bind(&grade.grade_type)
                .bind(&grade.description)
                .bind(grade.grade)
                .bind(grade.subject)
                .execute(pool)
                .await;
            if result.is_err() {
                return HttpResponse::InternalServerError().finish();
            } else {
                
            let (
                    reply_to,
                    subject_name,
                    sender_name,
                    receiver_name
                ): (String, String, String, String) =
                match sqlx::query_as::<_, (String, String, String, String)>(
                    r#"
                    SELECT 
                        u1.email, 
                        s.name, 
                        pd1.full_name AS sender_name, 
                        pd2.full_name AS receiver_name
                    FROM grades g
                    JOIN users u1 ON u1.id = g.student_id
                    JOIN subjects s ON s.id = g.subject_id
                    JOIN personal_data pd1 ON pd1.user_id = ?
                    JOIN personal_data pd2 ON pd2.user_id = g.student_id
                    WHERE g.student_id = ? AND g.subject_id = ?
                    "#
                )
                .bind(self.id)
                .bind(grade.student_id)
                .bind(grade.subject)
                .fetch_one(pool)
                .await
                .map_err(|e| HttpResponse::InternalServerError().json(e.to_string())) {
                    Ok(u) => u,
                    Err(e) => return e,
                };

                send_grade_email(
                    vec![reply_to],
                    &subject_name,
                    &sender_name,
                    &receiver_name,
                    &grade.grade.to_string(),
                ).await;
                return HttpResponse::Created().finish();
            }
           
        }
        let result = sqlx::query("INSERT INTO grades (student_id, grade_type, description, grade, subject_id) VALUES (?, ?, ?, ?, ?)")
            .bind(grade.student_id)
            .bind(&grade.grade_type)
            .bind(&grade.description)
            .bind(grade.grade)
            .bind(grade.subject)
            .execute(pool)
            .await;
        if result.is_err() {
            return HttpResponse::InternalServerError().finish();
        } else {

            return HttpResponse::Created().finish();
        }
    }
    async fn post_message(&self, pool: &MySqlPool, message: NewMessage) -> HttpResponse {
        // cheking if courses are valid
        let courses: Vec<u64> = message
            .courses
            .split(',')
            .filter_map(|s| s.trim().parse::<u64>().ok())
            .collect();
        for course in courses.iter() {
            if *course <= 0 || *course > 36 {
                return HttpResponse::BadRequest().json("Invalid courses");
            }
        }

        match self.role {
            Role::admin => {}
            Role::preceptor => {
                let preceptor_courses: Vec<u64> = match self.get_courses(pool).await {
                    Ok(c) => c.iter().map(|c| c.id).collect(),
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
                };
                dbg!(&preceptor_courses);
                if !preceptor_courses
                    .iter()
                    .any(|&course| courses.contains(&course))
                {
                    return HttpResponse::Unauthorized().finish();
                }
            }
            _ => {}
        };

        let message_id =
            match sqlx::query("INSERT INTO messages (message, sender_id, title) VALUES (?, ?, ?)")
                .bind(&message.message)
                .bind(self.id)
                .bind(&message.title)
                .execute(pool)
                .await
            {
                Ok(ref result) => result.last_insert_id(),
                Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
            };

        for course in courses.iter() {
            let _insert_result = match sqlx::query(
                "INSERT INTO message_courses (course_id, message_id) VALUES (?,?)",
            )
            .bind(course)
            .bind(message_id)
            .execute(pool)
            .await
            {
                Ok(r) => r,
                Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
            };
        }

        if !courses.is_empty() {
            let placeholders = courses.iter().map(|_| "?").collect::<Vec<_>>().join(",");
            let sql = format!(
                "SELECT u.email, pd.full_name FROM users u JOIN personal_data pd ON pd.user_id = u.id WHERE u.course_id IN ({})",
                placeholders
            );

            let mut query = sqlx::query_as::<_, (String, String)>(&sql);

            for course in &courses {
                query = query.bind(course);
            }

            let students: Vec<(String, String)> = match query.fetch_all(pool).await {
                Ok(list) => list,
                Err(_) => vec![],
            };

            let sender_name: String = match sqlx::query_scalar("SELECT full_name FROM personal_data WHERE user_id = ?")
                .bind(self.id)
                .fetch_one(pool)
                .await
            {
                Ok(name) => name,
                Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
            };
            crate::email::send_message_email(
                students,
                &sender_name,
                &message.message
            ).await;
        }
        HttpResponse::Created().finish()
    }

    async fn post_profile_picture(
        &self,
        pool: &MySqlPool,
        multipart: actix_multipart::Multipart,
    ) -> HttpResponse {
        let hashmap = match parse_multipart(
            multipart,
            Some(&["jpg", "jpeg", "png"]),
            Some(&["image/jpeg", "image/png"]),
            "./uploads/profile_pictures",
        )
        .await
        {
            Ok(h) => h,
            Err(e) => return HttpResponse::BadRequest().json(format!("Invalid upload: {}", e)),
        };

        let file_name = hashmap
            .get("file")
            .and_then(|bytes| str::from_utf8(bytes).ok());

        let result = sqlx::query("UPDATE users SET photo = ? WHERE id = ?")
            .bind(file_name)
            .bind(self.id)
            .execute(pool)
            .await;

        if result.is_err() {
            return HttpResponse::InternalServerError().finish();
        }

        HttpResponse::Created().finish()
    }
    async fn post_submission(&self, pool: &MySqlPool, multipart: Multipart) -> HttpResponse {
        match self.role {
            Role::student => {}
            _ => return HttpResponse::Unauthorized().finish(),
        };

        let user_course = match self.get_courses(pool).await {
            Ok(c) if !c.is_empty() => c[0].id,
            Ok(_) => return HttpResponse::NotFound().json("No course found"),
            Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
        };

        let hashmap = match parse_multipart(
            multipart,
            Some(&["pdf", "docx"]),
            Some(&[
                "application/pdf",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ]),
            "./uploads/submissions",
        )
        .await
        {
            Ok(h) => h,
            Err(e) => return HttpResponse::BadRequest().json(format!("Invalid upload: {}", e)),
        };

        let homework_id = match hashmap
            .get("homework_id")
            .and_then(|bytes| str::from_utf8(bytes).ok())
            .and_then(|s| s.parse::<u64>().ok())
        {
            Some(id) => id,
            None => return HttpResponse::BadRequest().json("Missing or invalid task_id"),
        };

        let file_name = match hashmap.get("file") {
            Some(f) => f,
            None => return HttpResponse::BadRequest().json("Missing file"),
        };

        let res: (String, u64) =
            match sqlx::query_as("SELECT type, subject_id FROM assessments WHERE id = ?")
                .bind(homework_id)
                .fetch_one(pool)
                .await
            {
                Ok(g) => g,
                Err(_) => {
                    return HttpResponse::InternalServerError().finish();
                }
            };

        if res.0 != "homework" {
            return HttpResponse::BadRequest().body("submission are only valid for homeworks");
        }
        let task_course =
            match sqlx::query_scalar::<_, u64>("SELECT course_id FROM subjects WHERE id = ?")
                .bind(res.1)
                .fetch_one(pool)
                .await
            {
                Ok(g) => g,
                Err(_) => {
                    return HttpResponse::InternalServerError().finish();
                }
            };

        if task_course != user_course {
            return HttpResponse::Unauthorized().finish();
        }

        let already_exists = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM homework_submissions WHERE student_id = ? AND task_id = ?)"
        )
        .bind(self.id)
        .bind(homework_id)
        .fetch_one(pool)
        .await;

        match already_exists {
            Ok(true) => {
                return HttpResponse::BadRequest().body("You already submitted this homework");
            }
            Ok(false) => {}
            Err(_) => {
                return HttpResponse::InternalServerError().finish();
            }
        }

        let result = sqlx::query(
            "INSERT INTO homework_submissions (path, student_id, task_id) VALUES (?, ?, ?)",
        )
        .bind(file_name)
        .bind(self.id)
        .bind(homework_id)
        .execute(pool)
        .await;

        if result.is_err() {
            return HttpResponse::InternalServerError().finish();
        }

        return HttpResponse::Created().body("Submission created");
    }

    async fn post_submission_selfassessable(
        &self,
        pool: &MySqlPool,
        task_submission: NewSubmissionSelfAssessable,
    ) -> HttpResponse {
        if self.role != Role::student {
            return HttpResponse::Unauthorized().finish();
        }

        let user_course =
            match sqlx::query_scalar::<_, u64>("SELECT course_id FROM users WHERE id = ?")
                .bind(self.id)
                .fetch_one(pool)
                .await
            {
                Ok(course_id) => course_id,
                Err(_) => return HttpResponse::InternalServerError().finish(),
            };

        let (assessment_type, subject_id, due_date): (String, u64, chrono::NaiveDate) =
            match sqlx::query_as("SELECT type, subject_id, due_date FROM assessments WHERE id = ?")
                .bind(task_submission.assessment_id)
                .fetch_one(pool)
                .await
            {
                Ok(res) => res,
                Err(e) => return HttpResponse::InternalServerError().body(e.to_string()),
            };

        if assessment_type != "selfassessable" {
            return HttpResponse::BadRequest().body("submission are only valid for selfassables");
        }

        let now = chrono::Utc::now();

        if now.date_naive() != due_date {
            let msg = format!(
                "Submission is only allowed on the {}",
                due_date.to_string());
            return HttpResponse::BadRequest().body(msg);
        }

        let assessable_course =
            match sqlx::query_scalar::<_, u64>("SELECT course_id FROM subjects WHERE id = ?")
                .bind(subject_id)
                .fetch_one(pool)
                .await
            {
                Ok(course_id) => course_id,
                Err(e) => return HttpResponse::InternalServerError().body(e.to_string()),
            };

        if assessable_course != user_course {
            return HttpResponse::Unauthorized().finish();
        }

        let selfassessable_id = match sqlx::query_scalar::<_, u64>(
            "SELECT id FROM selfassessables WHERE assessment_id = ?",
        )
        .bind(task_submission.assessment_id)
        .fetch_one(pool)
        .await
        {
            Ok(id) => id,
            Err(e) => return HttpResponse::InternalServerError().body(e.to_string()),
        };
    
        let assessment_id = task_submission.assessment_id;

        let already_exists = match self.get_is_selfassessable_answered(&pool, assessment_id).await {
            Ok(f) => f,
            Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
        };
        
        if already_exists {
            return HttpResponse::BadRequest().body("You already submitted this selfassessable");
        }

        let answers = task_submission.answers;

        let filter = SelfassessableFilter {
            assessment_id: Some(assessment_id),
        };

        let assessable_task = match self.get_selfassessables(&pool, filter).await {
            Ok(u) => u,
            Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
        };

        let corrects: Vec<String> = assessable_task.into_iter().map(|a| a.correct).collect();
        let mut grade = 0;

        for (answer, correct) in answers.iter().zip(corrects.iter()) {
            if answer == correct {
                grade += 1;
            }
        }
        let percentage = grade as f64 / answers.len() as f64;

        let result = sqlx::query("INSERT INTO selfassessable_pending_grades (selfassessable_id, student_id, grade) VALUES (?, ?, ?)")
            .bind(selfassessable_id)
            .bind(self.id)
            .bind(percentage * 10.0)
            .execute(pool)
            .await;
        if let Err(e) = result {
            return HttpResponse::InternalServerError().body(e.to_string());
        }
        match sqlx::query(
            "INSERT INTO selfassessable_submissions (selfassessable_id, student_id, answers) VALUES (?, ?, ?)"
        )
        .bind(selfassessable_id)
        .bind(self.id)
        .bind(answers.join(","))
        .execute(pool)
        .await {
            Ok(_) => HttpResponse::Created().finish(),
            Err(e) => HttpResponse::InternalServerError().body(e.to_string()),
        }
    }
    async fn post_subject_messages(&self, pool: &MySqlPool, multipart: Multipart) -> HttpResponse {
        // Parse multipart with allowed extensions and MIME types
        let hashmap = match parse_multipart(
            multipart,
            Some(&["pdf", "docx"]),
            Some(&[
                "application/pdf",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ]),
            "./uploads/files",
        )
        .await
        {
            Ok(h) => h,
            Err(e) => return HttpResponse::BadRequest().json(format!("Invalid upload: {}", e)),
        };

        // Extract and parse subject_id
        let subject_id = match hashmap
            .get("subject_id")
            .and_then(|bytes| str::from_utf8(bytes).ok())
            .and_then(|s| s.parse::<u64>().ok())
        {
            Some(id) => id,
            None => return HttpResponse::BadRequest().json("Missing or invalid subject_id"),
        };

        // Extract and parse type
        let type_ = match hashmap
            .get("type")
            .and_then(|bytes| str::from_utf8(bytes).ok())
        {
            Some(t) => t,
            None => "message",
        };

        let title = match hashmap
            .get("title")
            .and_then(|bytes| str::from_utf8(bytes).ok())
        {
            Some(t) => t,
            None => "",
        };

        // Extract content or file name
        let (content_or_file, is_text) = match type_ {
            "file" => match hashmap.get("file") {
                Some(f) => (f, false),
                None => return HttpResponse::BadRequest().json("Missing file"),
            },
            "message" => match hashmap.get("content") {
                Some(c) => match str::from_utf8(c) {
                    Ok(s) => (&s.as_bytes().to_vec(), true),
                    Err(_) => return HttpResponse::BadRequest().json("Invalid content encoding"),
                },
                None => return HttpResponse::BadRequest().json("Missing content"),
            },
            _ => return HttpResponse::BadRequest().json("Invalid type"),
        };

        // Authorization
        match self.role {
            Role::student | Role::father | Role::preceptor => {
                return HttpResponse::Unauthorized().finish();
            }
            Role::teacher => {
                let authorized: bool = match sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM subjects WHERE teacher_id = ? AND id = ?)",
                )
                .bind(self.id)
                .bind(subject_id)
                .fetch_one(pool)
                .await
                {
                    Ok(result) => result,
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string()),
                };

                if !authorized {
                    return HttpResponse::Unauthorized().finish();
                }
            }
            Role::admin => {}
        }

        // Insert message into database
        let insert_result = if is_text {
            // For text type, convert bytes back to string for database
            let content_str = str::from_utf8(content_or_file).unwrap_or("");
            sqlx::query(
                "INSERT INTO subject_messages (subject_id, sender_id, type, content, title) VALUES (?, ?, ?, ?, ?)"
            )
                .bind(subject_id)
                .bind(self.id)
                .bind(type_)
                .bind(content_str)
                .bind(title)
                .execute(pool)
                .await
        } else {
            // For file type, use the bytes directly (it's a file path)
            let file_path = str::from_utf8(content_or_file).unwrap_or("");
            sqlx::query(
            "INSERT INTO subject_messages (subject_id, sender_id, type, content, title) VALUES (?, ?, ?, ?, ?)"
        )
            .bind(subject_id)
            .bind(self.id)
            .bind(type_)
                .bind(file_path)
            .bind(title)
            .execute(pool)
                .await
        };

        match insert_result {
            Ok(_) => {
                // Enviar email a todos los estudiantes del curso de la materia
                let students: Vec<(String, String)> = match sqlx::query_as::<_, (String, String)>(
                    r#"
                    SELECT u.email, pd.full_name
                    FROM users u
                    JOIN personal_data pd ON pd.user_id = u.id
                    JOIN subjects s ON s.course_id = u.course_id
                    WHERE s.id = ?
                    "#
                )
                .bind(subject_id)
                .fetch_all(pool)
                .await
                {
                    Ok(list) => list,
                    Err(_) => vec![],
                };
                let sender_name: String = match sqlx::query_scalar("SELECT full_name FROM personal_data WHERE user_id = ?")
                    .bind(self.id)
                    .fetch_one(pool)
                    .await
                {
                    Ok(name) => name,
                    Err(_) => "Remitente".to_string(),
                };
                let subject_name: String = match sqlx::query_scalar("SELECT name FROM subjects WHERE id = ?")
                    .bind(subject_id)
                    .fetch_one(pool)
                    .await
                {
                    Ok(name) => name,
                    Err(_) => "Materia".to_string(),
                };
                let msg = if is_text {
                    str::from_utf8(content_or_file).unwrap_or("")
                } else {
                    "Archivo adjunto"
                };
                crate::email::send_subject_message_email(
                    students,
                    &sender_name,
                    &subject_name,
                    msg
                ).await;
                HttpResponse::Created().finish()
            },
            Err(e) => HttpResponse::InternalServerError().json(e.to_string()),
        }
    }
    async fn get_is_selfassessable_answered(
        &self,
        pool: &MySqlPool,
        assessment_id: u64,
    ) -> anyhow::Result<bool, sqlx::Error> {

        let selfassessable_id: u64 = match sqlx::query_scalar("SELECT id FROM selfassessables s WHERE s.assessment_id = ?")
            .bind(assessment_id)
            .fetch_one(pool)
            .await {
            Ok(id) => id,
            Err(e) => return Err(e),
        };

        let res = sqlx::query_scalar("SELECT EXISTS (SELECT * FROM selfassessable_submissions WHERE student_id = ? AND selfassessable_id = ?)")
            .bind(self.id)
            .bind(selfassessable_id)
            .fetch_one(pool)
            .await;
        res
    }
    async fn get_is_homework_answered(
        &self,
        pool: &MySqlPool,
        homework_id: u64,
    ) -> anyhow::Result<bool, sqlx::Error> {
        let res = sqlx::query_scalar("SELECT EXISTS (SELECT * FROM homework_submissions WHERE student_id = ? AND task_id = ?)")
            .bind(self.id)
            .bind(homework_id)
            .fetch_one(pool)
            .await;
        res
    }
    async fn post_assistance(
            &self,
            pool: &MySqlPool,
            assistance: NewAssistance
        ) -> HttpResponse {
    
        match self.role {
            Role::preceptor => {
                let courses = self.get_courses(pool).await.unwrap();
                let student_id = assistance.student_id;
                let student_course: u64 = match sqlx::query_scalar("SELECT course_id FROM users WHERE id = ?").bind(student_id).fetch_one(pool).await {
                    Ok(sc) => sc,
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string())
                };
                let has_access = courses.iter().any(|course| course.id == student_course);

                if !has_access {
                    return HttpResponse::Unauthorized().finish();
                }

            },
            Role::admin => {

            },
            _ => {
                return HttpResponse::Unauthorized().finish();
            }
        }
        let result = sqlx::query("INSERT INTO assistance (student_id, presence, date) VALUES (?, ?, ?)")
            .bind(assistance.student_id)
            .bind(assistance.presence)
            .bind(assistance.date)
            .execute(pool)
            .await;
        match result {
            Ok(_) => return HttpResponse::Created().finish(),
            Err(e) => return HttpResponse::InternalServerError().json(e.to_string())
        }
    }
    async fn post_disciplinary_sanction(
            &self,
            pool: &MySqlPool,
            ds: NewDisciplinarySanction
        ) -> HttpResponse {
        match self.role {
            Role::preceptor => {
                let courses = self.get_courses(pool).await.unwrap();
                let student_id = ds.student_id;
                let student_course: u64 = match sqlx::query_scalar("SELECT course_id FROM users WHERE id = ?").bind(student_id).fetch_one(pool).await {
                    Ok(sc) => sc,
                    Err(e) => return HttpResponse::InternalServerError().json(e.to_string())
                };
                let has_access = courses.iter().any(|course| course.id == student_course);

                if !has_access {
                    return HttpResponse::Unauthorized().finish();
                }

            },
            Role::admin => {

            },
            _ => {
                return HttpResponse::Unauthorized().finish();
            }
        }
        let result = sqlx::query("INSERT INTO disciplinary_sanction (student_id, sanction_type, quantity, description, date) VALUES (?, ?, ?, ?, ?)")
            .bind(ds.student_id)
            .bind(ds.sanction_type)
            .bind(ds.quantity)
            .bind(ds.description)
            .bind(ds.date)
            .execute(pool)
            .await;
        match result {
            Ok(_) => return HttpResponse::Created().finish(),
            Err(e) => return HttpResponse::InternalServerError().json(e.to_string())
        }
    }
}
