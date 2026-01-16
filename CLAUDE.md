# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GoSchool is a school management system for Colegio Stella Maris Rosario (Argentina). It consists of:
- **Backend**: Rust (Actix-web 4) REST API + WebSocket
- **Frontend**: Next.js 15 with React 19, TypeScript, Tailwind CSS 4
- **Database**: MySQL 8.0
- **Infrastructure**: Docker Compose with Nginx reverse proxy and Fail2ban

## Build and Run Commands

### Full Stack (Docker)
```bash
docker-compose up -d          # Start all services
docker-compose down           # Stop all services
docker-compose logs -f backend  # View backend logs
```

### Backend (Rust)
```bash
cd back
cargo build --release         # Build release binary
cargo check                   # Type check without building
```

### Frontend (Next.js)
```bash
cd front
npm install                   # Install dependencies
npm run dev                   # Dev server with Turbopack (port 3000)
npm run build                 # Production build
npm run lint                  # Run ESLint
```

### Database Setup
```bash
# Run inside init container or locally with Python
python3 create_database.py create_all    # Create tables and JWT keys
python3 create_database.py delete_tables # Drop all tables
```

### Test Users (DEBUG=true required)
Hit `/api/v1/register_testing_users/` to create test accounts:
| Role | Username | Password |
|------|----------|----------|
| admin | admin | admin |
| student | student | student |
| teacher | teacher | teacher |
| preceptor | preceptor | preceptor |
| father | father | father |

## Architecture

### Backend Structure (`back/src/`)
- `main.rs` - HTTP server setup, middleware configuration
- `routes.rs` - Route registration for all API endpoints
- `views/` - API endpoint handlers (27 files, organized by resource)
- `impls/` - Trait implementations for database operations
- `websocket/` - Real-time chat (handler.rs, manager.rs, protocol.rs)
- `jwt.rs` - ES256 JWT authentication
- `cron.rs` - Scheduled tasks (self-assessment auto-grading every 15min)
- `email.rs` - Email sending with Tera templates
- `filters.rs` - Query filtering logic
- `parse_multipart.rs` - File upload handling with MIME validation

### Frontend Structure (`front/src/`)
- `app/` - Next.js App Router pages and layouts
- `components/` - Reusable React components (Radix UI based)
- `hooks/` - Custom React hooks
- `store/` - Zustand state management
- `types/` - TypeScript type definitions
- `lib/` - Utility libraries (Axios instance, etc.)

### API Base URL
`/api/v1/` - All endpoints documented in `/back/README.md`

### Authentication
- JWT tokens with ES256 elliptic curve signature
- HTTP-only cookies (1-hour expiry)
- Role-based access: admin, teacher, student, preceptor, father

### Key Environment Variables
```bash
DATABASE_URL=mysql://user:password@host:3306/database
BASE_URL=https://127.0.0.1/      # Public-facing URL
BASE_PATH=/app                    # File storage base path
DEBUG=true                        # Enables test endpoints
NEXT_PUBLIC_BACKEND_URL=https://127.0.0.1  # Frontend -> Backend
```

## Code Patterns

### Backend Database Queries
Uses SQLx with parameterized queries. All database operations are async.

### Frontend API Calls
Uses Axios with credentials included. Server-side requests go through internal Docker network (`https://nginx:443`), client-side through `NEXT_PUBLIC_BACKEND_URL`.

### File Uploads
- Max size: 10MB
- MIME type validated by content (not extension)
- Files stored with UUID filenames
- Supported: images for profile pictures, documents for homework

### WebSocket Chat
Connect to `/api/v1/ws/` for real-time messaging. Protocol defined in `back/src/websocket/protocol.rs`.

## Educational Context
- Argentine educational terminology
- Primary: 1°-7° (divisions: Mar, Gaviota, Estrella)
- Secondary: 1°-6° (divisions: a, b, c)
- Shifts: morning/afternoon
