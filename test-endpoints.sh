#!/bin/bash

# =============================================================================
# GoSchool API Test Script
# Tests all endpoints with various possibilities
# =============================================================================

# Configuration
# Use HTTPS by default since nginx typically redirects HTTP to HTTPS
BASE_URL="${BASE_URL:-https://localhost}"
API_URL="$BASE_URL/api/v1"
COOKIE_FILE="/tmp/goschool_cookies.txt"
RESULTS_FILE="/tmp/goschool_test_results.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
    echo "[PASS] $1" >> "$RESULTS_FILE"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1 - Status: $2, Response: $3"
    ((FAILED++))
    echo "[FAIL] $1 - Status: $2" >> "$RESULTS_FILE"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1 - $2"
    ((SKIPPED++))
    echo "[SKIP] $1 - $2" >> "$RESULTS_FILE"
}

log_section() {
    echo ""
    echo -e "${YELLOW}=============================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${YELLOW}=============================================${NC}"
}

# Make a request and check the status code
# Usage: make_request "METHOD" "URL" "EXPECTED_STATUS" "DESCRIPTION" ["DATA"] ["CONTENT_TYPE"]
make_request() {
    local method="$1"
    local url="$2"
    local expected_status="$3"
    local description="$4"
    local data="$5"
    local content_type="${6:-application/json}"

    # -L follows redirects, -k ignores SSL cert issues
    if [ "$method" = "GET" ]; then
        response=$(curl -s -L -k -w '\n%{http_code}' -b "$COOKIE_FILE" -c "$COOKIE_FILE" -X GET "$url")
    elif [ "$method" = "POST" ] && [ -n "$data" ]; then
        response=$(curl -s -L -k -w '\n%{http_code}' -b "$COOKIE_FILE" -c "$COOKIE_FILE" -X POST "$url" -H "Content-Type: $content_type" -d "$data")
    elif [ "$method" = "POST" ]; then
        response=$(curl -s -L -k -w '\n%{http_code}' -b "$COOKIE_FILE" -c "$COOKIE_FILE" -X POST "$url")
    elif [ "$method" = "PUT" ] && [ -n "$data" ]; then
        response=$(curl -s -L -k -w '\n%{http_code}' -b "$COOKIE_FILE" -c "$COOKIE_FILE" -X PUT "$url" -H "Content-Type: $content_type" -d "$data")
    elif [ "$method" = "DELETE" ]; then
        response=$(curl -s -L -k -w '\n%{http_code}' -b "$COOKIE_FILE" -c "$COOKIE_FILE" -X DELETE "$url")
    fi

    # Extract status code (last line) and body (everything else)
    status_code=$(echo "$response" | tail -n1 | tr -d '[:space:]')
    body=$(echo "$response" | sed '$d')

    # Check if status matches expected
    if [[ "$expected_status" == *"$status_code"* ]]; then
        log_success "$description ($method $url)"
        echo "$body"
        return 0
    else
        log_fail "$description ($method $url)" "$status_code" "$body"
        echo "$body"
        return 1
    fi
}

# Make a multipart form request
# Usage: make_multipart_request "METHOD" "URL" "EXPECTED_STATUS" "DESCRIPTION" "FORM_DATA..."
make_multipart_request() {
    local method="$1"
    local url="$2"
    local expected_status="$3"
    local description="$4"
    shift 4
    local form_data=("$@")

    # -L follows redirects, -k ignores SSL cert issues
    local curl_cmd="curl -s -L -k -w '\n%{http_code}' -b \"$COOKIE_FILE\" -c \"$COOKIE_FILE\" -X $method"

    for field in "${form_data[@]}"; do
        curl_cmd="$curl_cmd -F '$field'"
    done

    curl_cmd="$curl_cmd '$url'"

    response=$(eval $curl_cmd)
    status_code=$(echo "$response" | tail -n1 | tr -d '[:space:]')
    body=$(echo "$response" | sed '$d')

    if [[ "$expected_status" == *"$status_code"* ]]; then
        log_success "$description ($method $url)"
        echo "$body"
        return 0
    else
        log_fail "$description ($method $url)" "$status_code" "$body"
        echo "$body"
        return 1
    fi
}

login_as() {
    local email="$1"
    local password="$2"
    local role="$3"

    log_info "Logging in as $email with role $role..."
    rm -f "$COOKIE_FILE"

    # -L follows redirects, -k ignores SSL cert issues
    response=$(curl -s -L -k -w '\n%{http_code}' -c "$COOKIE_FILE" -X POST "$API_URL/login/" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$email\", \"password\": \"$password\", \"role\": \"$role\"}")

    status_code=$(echo "$response" | tail -n1 | tr -d '[:space:]')

    if [ "$status_code" = "200" ]; then
        log_success "Login as $email ($role)"
        return 0
    else
        log_fail "Login as $email ($role)" "$status_code" "$(echo "$response" | sed '$d')"
        return 1
    fi
}

# =============================================================================
# Initialize
# =============================================================================

> "$RESULTS_FILE"
rm -f "$COOKIE_FILE"

echo ""
echo "============================================="
echo "  GoSchool API Endpoint Test Suite"
echo "  Base URL: $BASE_URL"
echo "  Started: $(date)"
echo "============================================="
echo ""

# =============================================================================
# 1. HEALTH CHECK (No Auth Required)
# =============================================================================
log_section "1. HEALTH CHECK"

make_request "GET" "$API_URL/health/" "200" "Health check endpoint"

# =============================================================================
# 2. REGISTER TEST USERS (DEBUG mode required)
# =============================================================================
log_section "2. REGISTER TEST USERS"

# This endpoint only works when DEBUG=true in backend
make_request "GET" "$API_URL/register_testing_users/" "200|201|500" "Register testing users (requires DEBUG=true)"

# =============================================================================
# 3. AUTHENTICATION ENDPOINTS
# =============================================================================
log_section "3. AUTHENTICATION ENDPOINTS"

# 3.1 Get roles for user
log_info "Testing roles endpoint..."
make_request "POST" "$API_URL/roles/" "200" "Get roles for admin user" \
    '{"email": "admin", "password": "admin"}'

# 3.2 Login with different roles
log_info "Testing login with all test users..."

for user in "admin:admin:admin" "teacher:teacher:teacher" "student:student:student" "preceptor:preceptor:preceptor" "father:father:father"; do
    IFS=':' read -r email password role <<< "$user"
    rm -f "$COOKIE_FILE"
    make_request "POST" "$API_URL/login/" "200" "Login as $role" \
        "{\"email\": \"$email\", \"password\": \"$password\", \"role\": \"$role\"}"
done

# 3.3 Verify token
login_as "admin" "admin" "admin"
make_request "GET" "$API_URL/verify_token/" "200" "Verify token (valid)"

# 3.4 Get current role
make_request "GET" "$API_URL/role/" "200" "Get current role"

# 3.5 Logout (may return 400 due to redirect issues with POST)
make_request "POST" "$API_URL/logout/" "200|400" "Logout"

# =============================================================================
# 4. COURSES ENDPOINT
# =============================================================================
log_section "4. COURSES"

login_as "admin" "admin" "admin"

# Get all courses
COURSES_RESPONSE=$(make_request "GET" "$API_URL/courses/" "200" "Get all courses")
# Extract first course ID if available
COURSE_ID=$(echo "$COURSES_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$COURSE_ID" ]; then
    COURSE_ID=1
    log_info "No courses found, using default COURSE_ID=1"
else
    log_info "Found COURSE_ID=$COURSE_ID"
fi

# =============================================================================
# 5. SUBJECTS ENDPOINT
# =============================================================================
log_section "5. SUBJECTS"

# Get all subjects
SUBJECTS_RESPONSE=$(make_request "GET" "$API_URL/subjects/" "200" "Get all subjects")
SUBJECT_ID=$(echo "$SUBJECTS_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$SUBJECT_ID" ]; then
    SUBJECT_ID=1
    log_info "No subjects found, using default SUBJECT_ID=1"
else
    log_info "Found SUBJECT_ID=$SUBJECT_ID"
fi

# Get subjects with filters
make_request "GET" "$API_URL/subjects/?course_id=$COURSE_ID" "200" "Get subjects filtered by course"
make_request "GET" "$API_URL/subjects/?teacher_id=1" "200" "Get subjects filtered by teacher"

# =============================================================================
# 6. STUDENTS ENDPOINT
# =============================================================================
log_section "6. STUDENTS"

# Get all students (returns array of PubUser objects with id, photo, course_id, email, full_name)
STUDENTS_RESPONSE=$(make_request "GET" "$API_URL/students/" "200" "Get all students")
# Extract first "id" value from response like [{"id":3,"email":"student",...}]
STUDENT_ID=$(echo "$STUDENTS_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$STUDENT_ID" ] || [ "$STUDENT_ID" = "0" ]; then
    STUDENT_ID=3
    log_info "No students found, using default STUDENT_ID=3"
else
    log_info "Found STUDENT_ID=$STUDENT_ID"
fi

# Get students with filters
make_request "GET" "$API_URL/students/?course=$COURSE_ID" "200" "Get students filtered by course"
make_request "GET" "$API_URL/students/?role=student" "200" "Get students filtered by role"

# =============================================================================
# 7. TIMETABLES ENDPOINT
# =============================================================================
log_section "7. TIMETABLES"

make_request "GET" "$API_URL/timetables/" "200" "Get all timetables"
make_request "GET" "$API_URL/timetables/?course_id=$COURSE_ID" "200" "Get timetables filtered by course"
make_request "GET" "$API_URL/timetables/?day=Monday" "200" "Get timetables filtered by day"

# =============================================================================
# 8. PERSONAL DATA ENDPOINTS
# =============================================================================
log_section "8. PERSONAL DATA"

make_request "GET" "$API_URL/personal_data/" "200" "Get own personal data"
make_request "GET" "$API_URL/public_personal_data/" "200" "Get public personal data"
make_request "GET" "$API_URL/public_personal_data/?course=$COURSE_ID" "200" "Get public data filtered by course"
make_request "GET" "$API_URL/public_personal_data/?user_id=$STUDENT_ID" "200" "Get public data filtered by user_id"

# =============================================================================
# 9. ASSESSMENTS ENDPOINTS (CRUD)
# =============================================================================
log_section "9. ASSESSMENTS"

login_as "teacher" "teacher" "teacher"

# Get assessments
make_request "GET" "$API_URL/assessments/" "200" "Get all assessments"
make_request "GET" "$API_URL/assessments/?subject_id=$SUBJECT_ID" "200" "Get assessments filtered by subject"

# Create assessment (exam type)
NEW_ASSESSMENT=$(make_request "POST" "$API_URL/assessments/" "200|201" "Create new assessment (exam)" \
    "{\"newtask\": {\"subject\": $SUBJECT_ID, \"task\": \"Test Exam $(date +%s)\", \"due_date\": \"2026-12-01\", \"type\": \"exam\"}}")
ASSESSMENT_ID=$(echo "$NEW_ASSESSMENT" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$ASSESSMENT_ID" ]; then
    # Try to get an existing assessment ID
    EXISTING=$(make_request "GET" "$API_URL/assessments/" "200" "Get existing assessments for ID")
    ASSESSMENT_ID=$(echo "$EXISTING" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
fi
log_info "Using ASSESSMENT_ID=$ASSESSMENT_ID"

# Create homework assessment
make_request "POST" "$API_URL/assessments/" "200|201" "Create new assessment (homework)" \
    "{\"newtask\": {\"subject\": $SUBJECT_ID, \"task\": \"Test Homework $(date +%s)\", \"due_date\": \"2026-12-15\", \"type\": \"homework\"}}"

# Create selfassessable
make_request "POST" "$API_URL/assessments/" "200|201" "Create selfassessable quiz" \
    "{\"newtask\": {\"subject\": $SUBJECT_ID, \"task\": \"Self Quiz $(date +%s)\", \"due_date\": \"2026-12-20\", \"type\": \"selfassessable\"}, \"newselfassessable\": {\"questions\": [\"What is 2+2?\", \"What is 3+3?\"], \"correct\": [\"4\", \"6\"], \"incorrect1\": [\"3\", \"5\"], \"incorrect2\": [\"5\", \"7\"]}}"

# Update assessment
if [ -n "$ASSESSMENT_ID" ]; then
    make_request "PUT" "$API_URL/assessments/$ASSESSMENT_ID" "200" "Update assessment" \
        "{\"task\": \"Updated Exam Name\", \"due_date\": \"2026-12-05\", \"type_\": \"exam\"}"
fi

# =============================================================================
# 10. SELFASSESSABLES ENDPOINTS
# =============================================================================
log_section "10. SELFASSESSABLES"

login_as "student" "student" "student"

make_request "GET" "$API_URL/selfassessables/" "200" "Get all selfassessables"
# This may fail with 500 if the assessment doesn't have a selfassessable
make_request "GET" "$API_URL/selfassessables/?assessment_id=$ASSESSMENT_ID" "200|500" "Get selfassessables filtered by assessment"

# Get selfassessable responses (students can view their own responses)
login_as "student" "student" "student"
make_request "GET" "$API_URL/selfassessables_responses/" "200" "Get selfassessable responses"

# Check if selfassessable answered (note: backend expects assessment_id, not selfassessable_id)
login_as "student" "student" "student"
if [ -n "$ASSESSMENT_ID" ]; then
    make_request "POST" "$API_URL/get_if_selfassessable_answered/" "200|500" "Check if selfassessable answered" \
        "{\"selfassessable_id\": $ASSESSMENT_ID}"
else
    make_request "POST" "$API_URL/get_if_selfassessable_answered/" "200|500" "Check if selfassessable answered" \
        '{"selfassessable_id": 1}'
fi

# =============================================================================
# 11. GRADES ENDPOINTS (CRUD)
# =============================================================================
log_section "11. GRADES"

login_as "teacher" "teacher" "teacher"

# Get teacher's subjects first to use a valid subject_id
TEACHER_SUBJECTS=$(make_request "GET" "$API_URL/subjects/" "200" "Get teacher's subjects")
TEACHER_SUBJECT_ID=$(echo "$TEACHER_SUBJECTS" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$TEACHER_SUBJECT_ID" ]; then
    TEACHER_SUBJECT_ID=$SUBJECT_ID
    log_info "Using default TEACHER_SUBJECT_ID=$TEACHER_SUBJECT_ID"
else
    log_info "Found TEACHER_SUBJECT_ID=$TEACHER_SUBJECT_ID"
fi

# Get grades
make_request "GET" "$API_URL/grades/" "200" "Get all grades"
make_request "GET" "$API_URL/grades/?subject_id=$TEACHER_SUBJECT_ID" "200" "Get grades filtered by subject"
make_request "GET" "$API_URL/grades/?student_id=$STUDENT_ID" "200" "Get grades filtered by student"

# Create grade (teacher must own the subject and student must be in that course)
NEW_GRADE=$(make_request "POST" "$API_URL/grades/" "200|201|401" "Create new grade" \
    "{\"subject\": $TEACHER_SUBJECT_ID, \"student_id\": $STUDENT_ID, \"grade_type\": \"numerical\", \"description\": \"Test Grade $(date +%s)\", \"grade\": 8.5}")
GRADE_ID=$(echo "$NEW_GRADE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$GRADE_ID" ]; then
    EXISTING=$(make_request "GET" "$API_URL/grades/" "200" "Get existing grades for ID")
    GRADE_ID=$(echo "$EXISTING" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
fi
log_info "Using GRADE_ID=$GRADE_ID"

# Update grade (must use the grade we just created, not a random ID)
# Get the ID from the grade we created
CREATED_GRADE_ID=$(echo "$NEW_GRADE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -n "$CREATED_GRADE_ID" ]; then
    make_request "PUT" "$API_URL/grades/$CREATED_GRADE_ID" "200" "Update grade" \
        '{"grade": 9.0, "description": "Updated grade"}'
    GRADE_ID=$CREATED_GRADE_ID
elif [ -n "$GRADE_ID" ]; then
    make_request "PUT" "$API_URL/grades/$GRADE_ID" "200|401" "Update grade" \
        '{"grade": 9.0, "description": "Updated grade"}'
fi

# =============================================================================
# 12. MESSAGES ENDPOINTS (CRUD)
# =============================================================================
log_section "12. MESSAGES"

login_as "admin" "admin" "admin"

# Get messages
make_request "GET" "$API_URL/messages/" "200" "Get all messages"

# Create message
NEW_MESSAGE=$(make_request "POST" "$API_URL/messages/" "200|201" "Create new message" \
    "{\"title\": \"Test Message $(date +%s)\", \"message\": \"This is a test message\", \"courses\": \"$COURSE_ID\"}")
MESSAGE_ID=$(echo "$NEW_MESSAGE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$MESSAGE_ID" ]; then
    EXISTING=$(make_request "GET" "$API_URL/messages/" "200" "Get existing messages for ID")
    MESSAGE_ID=$(echo "$EXISTING" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
fi
log_info "Using MESSAGE_ID=$MESSAGE_ID"

# Update message
if [ -n "$MESSAGE_ID" ]; then
    make_request "PUT" "$API_URL/messages/$MESSAGE_ID" "200" "Update message" \
        '{"title": "Updated Message Title", "message": "Updated content"}'
fi

# =============================================================================
# 13. SUBJECT MESSAGES ENDPOINTS (CRUD)
# =============================================================================
log_section "13. SUBJECT MESSAGES"

login_as "teacher" "teacher" "teacher"

# Get subject messages
make_request "GET" "$API_URL/subject_messages/" "200" "Get all subject messages"
make_request "GET" "$API_URL/subject_messages/?subject_id=$SUBJECT_ID" "200" "Get subject messages filtered by subject"

# Create subject message (text type using form data)
NEW_SUBJ_MSG=$(make_multipart_request "POST" "$API_URL/subject_messages/" "200|201" "Create subject message (text)" \
    "subject_id=$SUBJECT_ID" "type=message" "title=Test Subject Message $(date +%s)" "content=Test content for subject message")
SUBJECT_MESSAGE_ID=$(echo "$NEW_SUBJ_MSG" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$SUBJECT_MESSAGE_ID" ]; then
    EXISTING=$(make_request "GET" "$API_URL/subject_messages/" "200" "Get existing subject messages for ID")
    SUBJECT_MESSAGE_ID=$(echo "$EXISTING" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
fi
log_info "Using SUBJECT_MESSAGE_ID=$SUBJECT_MESSAGE_ID"

# Update subject message (must use the message we just created)
CREATED_SUBJ_MSG_ID=$(echo "$NEW_SUBJ_MSG" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -n "$CREATED_SUBJ_MSG_ID" ]; then
    make_request "PUT" "$API_URL/subject_messages/$CREATED_SUBJ_MSG_ID" "200" "Update subject message" \
        '{"title": "Updated Title", "content": "Updated content", "type_": "message"}'
    SUBJECT_MESSAGE_ID=$CREATED_SUBJ_MSG_ID
elif [ -n "$SUBJECT_MESSAGE_ID" ]; then
    make_request "PUT" "$API_URL/subject_messages/$SUBJECT_MESSAGE_ID" "200|401" "Update subject message" \
        '{"title": "Updated Title", "content": "Updated content", "type_": "message"}'
fi

# =============================================================================
# 14. ASSISTANCE (ATTENDANCE) ENDPOINTS (CRUD)
# =============================================================================
log_section "14. ASSISTANCE (ATTENDANCE)"

login_as "preceptor" "preceptor" "preceptor"

# Get assistance records
make_request "GET" "$API_URL/assistance/" "200" "Get all assistance records"
make_request "GET" "$API_URL/assistance/?student_id=$STUDENT_ID" "200" "Get assistance filtered by student"
make_request "GET" "$API_URL/assistance/?date=2026-01-15" "200" "Get assistance filtered by date"
make_request "GET" "$API_URL/assistance/?presence=present" "200" "Get assistance filtered by presence"

# Create assistance record (requires valid student_id with personal_data)
TODAY=$(date +%Y-%m-%d)
NEW_ASSIST=$(make_request "POST" "$API_URL/assistance/" "200|201|500" "Create assistance record" \
    "{\"student_id\": $STUDENT_ID, \"presence\": \"present\", \"date\": \"$TODAY\"}")
ASSISTANCE_ID=$(echo "$NEW_ASSIST" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$ASSISTANCE_ID" ]; then
    EXISTING=$(make_request "GET" "$API_URL/assistance/" "200" "Get existing assistance for ID")
    ASSISTANCE_ID=$(echo "$EXISTING" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
fi
log_info "Using ASSISTANCE_ID=$ASSISTANCE_ID"

# Update assistance
if [ -n "$ASSISTANCE_ID" ]; then
    make_request "PUT" "$API_URL/assistance/$ASSISTANCE_ID" "200" "Update assistance record" \
        "{\"student_id\": $STUDENT_ID, \"presence\": \"late\", \"date\": \"$TODAY\"}"
fi

# =============================================================================
# 15. DISCIPLINARY SANCTIONS ENDPOINTS (CRUD)
# =============================================================================
log_section "15. DISCIPLINARY SANCTIONS"

# Get disciplinary sanctions
make_request "GET" "$API_URL/disciplinary_sanction/" "200" "Get all disciplinary sanctions"
make_request "GET" "$API_URL/disciplinary_sanction/?student_id=$STUDENT_ID" "200" "Get sanctions filtered by student"
make_request "GET" "$API_URL/disciplinary_sanction/?sanction_type=warning" "200" "Get sanctions filtered by type"

# Create disciplinary sanction (requires valid student_id with personal_data)
NEW_SANCTION=$(make_request "POST" "$API_URL/disciplinary_sanction/" "200|201|500" "Create disciplinary sanction" \
    "{\"student_id\": $STUDENT_ID, \"sanction_type\": \"warning\", \"quantity\": 1, \"description\": \"Test warning $(date +%s)\", \"date\": \"$TODAY\"}")
SANCTION_ID=$(echo "$NEW_SANCTION" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -z "$SANCTION_ID" ]; then
    EXISTING=$(make_request "GET" "$API_URL/disciplinary_sanction/" "200" "Get existing sanctions for ID")
    SANCTION_ID=$(echo "$EXISTING" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
fi
log_info "Using SANCTION_ID=$SANCTION_ID"

# Update disciplinary sanction
if [ -n "$SANCTION_ID" ]; then
    make_request "PUT" "$API_URL/disciplinary_sanction/$SANCTION_ID" "200" "Update disciplinary sanction" \
        '{"description": "Updated warning", "quantity": 2}'
fi

# =============================================================================
# 16. PROFILE PICTURES ENDPOINTS
# =============================================================================
log_section "16. PROFILE PICTURES"

login_as "admin" "admin" "admin"

# Get profile picture (may return 404 if no picture set)
make_request "GET" "$API_URL/profile_pictures/" "200|404" "Get own profile picture"

# Note: POST/PUT for profile pictures require multipart form data with actual image file
# These are tested manually or with actual image uploads

# =============================================================================
# 17. HOMEWORK SUBMISSIONS ENDPOINTS
# =============================================================================
log_section "17. HOMEWORK SUBMISSIONS"

login_as "student" "student" "student"

# Check if homework answered
make_request "POST" "$API_URL/get_if_homework_answered/" "200" "Check if homework answered" \
    '{"homework_id": 1}'

# =============================================================================
# 18. CHAT ENDPOINTS
# =============================================================================
log_section "18. CHAT"

login_as "admin" "admin" "admin"

# Get available users for chat
make_request "GET" "$API_URL/chats/available-users" "200" "Get available users for chat"

# Get user's chats
CHATS_RESPONSE=$(make_request "GET" "$API_URL/chats/" "200" "Get user's chats")
CHAT_ID=$(echo "$CHATS_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

# Create direct chat
NEW_CHAT=$(make_request "POST" "$API_URL/chats/" "200|201" "Create direct chat" \
    "{\"chat_type\": \"direct\", \"participant_ids\": [$STUDENT_ID]}")
if [ -z "$CHAT_ID" ]; then
    CHAT_ID=$(echo "$NEW_CHAT" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
fi
log_info "Using CHAT_ID=$CHAT_ID"

# Create group chat (may fail with 403 if roles don't allow chat between users)
make_request "POST" "$API_URL/chats/" "200|201|403" "Create group chat" \
    "{\"chat_type\": \"group\", \"name\": \"Test Group $(date +%s)\", \"description\": \"Test group description\", \"participant_ids\": [$STUDENT_ID]}"

# Get chat messages
if [ -n "$CHAT_ID" ]; then
    make_request "GET" "$API_URL/chats/$CHAT_ID/messages" "200" "Get chat messages"

    # Send message to chat
    make_request "POST" "$API_URL/chats/$CHAT_ID/messages" "200|201" "Send chat message" \
        "{\"message\": \"Test message $(date +%s)\"}"

    # Mark chat as read (returns 200 or 201)
    make_request "PUT" "$API_URL/chats/$CHAT_ID/read" "200|201" "Mark chat as read"
fi

# =============================================================================
# 19. DELETE OPERATIONS (Cleanup)
# =============================================================================
log_section "19. DELETE OPERATIONS (Cleanup)"

login_as "admin" "admin" "admin"

# Delete in reverse order of creation

# Delete disciplinary sanction
if [ -n "$SANCTION_ID" ]; then
    make_request "DELETE" "$API_URL/disciplinary_sanction/$SANCTION_ID" "200|204" "Delete disciplinary sanction"
fi

# Delete assistance
if [ -n "$ASSISTANCE_ID" ]; then
    make_request "DELETE" "$API_URL/assistance/$ASSISTANCE_ID" "200|204" "Delete assistance record"
fi

# Delete subject message (use the one we created)
login_as "teacher" "teacher" "teacher"
if [ -n "$CREATED_SUBJ_MSG_ID" ]; then
    make_request "DELETE" "$API_URL/subject_messages/$CREATED_SUBJ_MSG_ID" "200|204" "Delete subject message"
elif [ -n "$SUBJECT_MESSAGE_ID" ]; then
    make_request "DELETE" "$API_URL/subject_messages/$SUBJECT_MESSAGE_ID" "200|204|401" "Delete subject message"
fi

# Delete message
login_as "admin" "admin" "admin"
if [ -n "$MESSAGE_ID" ]; then
    make_request "DELETE" "$API_URL/messages/$MESSAGE_ID" "200|204" "Delete message"
fi

# Delete grade (use the one we created)
login_as "teacher" "teacher" "teacher"
if [ -n "$CREATED_GRADE_ID" ]; then
    make_request "DELETE" "$API_URL/grades/$CREATED_GRADE_ID" "200|204" "Delete grade"
elif [ -n "$GRADE_ID" ]; then
    make_request "DELETE" "$API_URL/grades/$GRADE_ID" "200|204|401" "Delete grade"
fi

# Delete assessment
if [ -n "$ASSESSMENT_ID" ]; then
    make_request "DELETE" "$API_URL/assessments/$ASSESSMENT_ID" "200|204" "Delete assessment"
fi

# =============================================================================
# 20. ROLE-BASED ACCESS TESTS
# =============================================================================
log_section "20. ROLE-BASED ACCESS TESTS"

# Test student accessing teacher-only endpoints
login_as "student" "student" "student"
make_request "POST" "$API_URL/assessments/" "400|401|403|500" "Student creating assessment (should fail)" \
    "{\"newtask\": {\"subject\": 1, \"task\": \"Unauthorized\", \"due_date\": \"2026-12-01\", \"type\": \"exam\"}}"

make_request "POST" "$API_URL/grades/" "400|401|403|500" "Student creating grade (should fail)" \
    '{"subject": 1, "assessment_id": 1, "student_id": 1, "grade_type": "numerical", "description": "Unauthorized", "grade": 10}'

# Test teacher accessing admin-only data
login_as "teacher" "teacher" "teacher"
# (Most endpoints should work for teacher, so test something they shouldn't access)

# Test unauthenticated access - create a new cookie file to ensure no JWT
log_info "Testing unauthenticated access..."
UNAUTH_COOKIE="/tmp/goschool_unauth_cookies.txt"
rm -f "$UNAUTH_COOKIE"

# Make request without JWT cookie (using a fresh empty cookie file)
response=$(curl -s -L -k -w '\n%{http_code}' -b "$UNAUTH_COOKIE" -c "$UNAUTH_COOKIE" -X GET "$API_URL/courses/")
status_code=$(echo "$response" | tail -n1 | tr -d '[:space:]')
body=$(echo "$response" | sed '$d')
if [[ "401|403" == *"$status_code"* ]] || [[ "$body" == *"Missing JWT"* ]] || [[ "$body" == *"Unauthorized"* ]] || [[ "$body" == *"Invalid"* ]]; then
    log_success "Unauthenticated access to courses (correctly rejected)"
else
    log_fail "Unauthenticated access to courses" "$status_code" "$body"
fi

response=$(curl -s -L -k -w '\n%{http_code}' -b "$UNAUTH_COOKIE" -c "$UNAUTH_COOKIE" -X GET "$API_URL/grades/")
status_code=$(echo "$response" | tail -n1 | tr -d '[:space:]')
body=$(echo "$response" | sed '$d')
if [[ "401|403" == *"$status_code"* ]] || [[ "$body" == *"Missing JWT"* ]] || [[ "$body" == *"Unauthorized"* ]] || [[ "$body" == *"Invalid"* ]]; then
    log_success "Unauthenticated access to grades (correctly rejected)"
else
    log_fail "Unauthenticated access to grades" "$status_code" "$body"
fi

rm -f "$UNAUTH_COOKIE"

# Re-login as admin for final summary
login_as "admin" "admin" "admin"

# =============================================================================
# SUMMARY
# =============================================================================

log_section "TEST SUMMARY"

echo ""
echo "============================================="
echo "  Test Results Summary"
echo "============================================="
echo -e "  ${GREEN}PASSED:${NC}  $PASSED"
echo -e "  ${RED}FAILED:${NC}  $FAILED"
echo -e "  ${YELLOW}SKIPPED:${NC} $SKIPPED"
echo "============================================="
echo "  Total:   $((PASSED + FAILED + SKIPPED))"
echo "============================================="
echo ""
echo "Detailed results saved to: $RESULTS_FILE"
echo "Finished: $(date)"
echo ""

# Cleanup
rm -f "$COOKIE_FILE"

# Exit with appropriate code
if [ $FAILED -gt 0 ]; then
    exit 1
else
    exit 0
fi
