-- WARNING: This schema is for context only and is not meant to be run.
-- Table order and constraints may not be valid for execution.

CREATE TABLE dev.ai_processing_queue (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  sender_id text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending'::text,
  process_at timestamp with time zone NOT NULL,
  CONSTRAINT ai_processing_queue_pkey PRIMARY KEY (id)
);
CREATE TABLE dev.chat (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  session_id text,
  title text,
  user_id text,
  CONSTRAINT chat_pkey PRIMARY KEY (id)
);
CREATE TABLE dev.conversation (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  chat_id bigint,
  type text,
  content text,
  CONSTRAINT conversation_pkey PRIMARY KEY (id),
  CONSTRAINT conversation_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chat(id)
);
CREATE TABLE dev.digests (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  user_id text,
  content text,
  from date,
  until date,
  CONSTRAINT digests_pkey PRIMARY KEY (id),
  CONSTRAINT digests_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE dev.email_threads (
  id text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  summary text,
  CONSTRAINT email_threads_pkey PRIMARY KEY (id)
);
CREATE TABLE dev.emails (
  email_id text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  summary text NOT NULL,
  original_link text NOT NULL,
  sender text NOT NULL,
  subject text,
  date_received date NOT NULL,
  user_id text NOT NULL,
  sender_name text,
  sender_email text,
  thread_id text,
  body text,
  relevant boolean NOT NULL DEFAULT true,
  ios_link text,
  html_body text,
  attachments_metadata jsonb,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  relevance_explanation text DEFAULT ''::text,
  cc_emails text,
  recipient_emails text,
  CONSTRAINT emails_pkey PRIMARY KEY (id),
  CONSTRAINT emails_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES public.email_threads(id),
  CONSTRAINT emails_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE dev.preferences (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  user_id text,
  name text NOT NULL,
  CONSTRAINT preferences_pkey PRIMARY KEY (id),
  CONSTRAINT preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE dev.task_agent_chat_histories (
  id integer NOT NULL DEFAULT nextval('dev.task_agent_chat_histories_id_seq'::regclass),
  session_id text NOT NULL,
  message jsonb NOT NULL,
  CONSTRAINT task_agent_chat_histories_pkey PRIMARY KEY (id)
);
CREATE TABLE dev.tasks (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  description text NOT NULL,
  due_date text DEFAULT 'Check original email'::text,
  category text,
  priority text,
  feedback integer DEFAULT 0 CHECK (feedback >= '-1'::integer AND feedback <= 1),
  user_id text NOT NULL,
  email_id text NOT NULL,
  progress text,
  app_link text,
  app_name text,
  chat_id bigint,
  draft_response text,
  time_blocked text,
  user_feedback ARRAY,
  extracted_from_id uuid,
  description_extended text,
  CONSTRAINT tasks_pkey PRIMARY KEY (id),
  CONSTRAINT tasks_extracted_from_id_fkey FOREIGN KEY (extracted_from_id) REFERENCES public.emails(id)
);
CREATE TABLE dev.telegram_messages (
  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  telegram_date bigint,
  telegram_date_utc timestamp with time zone,
  sender_id text,
  recipient_id text,
  text text,
  raw_payload jsonb,
  attachments jsonb,
  direction text,
  tool_activity jsonb,
  processed_by_ai_at timestamp with time zone,
  CONSTRAINT telegram_messages_pkey PRIMARY KEY (id)
);
CREATE TABLE dev.tz_presence_cache (
  user_id text NOT NULL,
  tz text,
  source text,
  strength numeric CHECK (strength >= 0::numeric AND strength <= 1::numeric),
  observed_at timestamp with time zone,
  committed_at timestamp with time zone,
  last_checked_at timestamp with time zone,
  last_message_id bigint,
  evidence_message_id bigint,
  evidence_text text,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tz_presence_cache_pkey PRIMARY KEY (user_id)
);
CREATE TABLE dev.user_logs (
  id bigint NOT NULL DEFAULT nextval('dev.user_logs_id_seq'::regclass),
  created_at timestamp with time zone DEFAULT now(),
  user_id text,
  user_email text,
  event_type text NOT NULL,
  event_data jsonb,
  success boolean DEFAULT true,
  error_message text,
  session_id text,
  ip_address inet,
  user_agent text,
  CONSTRAINT user_logs_pkey PRIMARY KEY (id),
  CONSTRAINT user_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE dev.users (
  id text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  email text NOT NULL,
  display_name text,
  provider text,
  access_token text,
  refresh_token text,
  expires_in integer,
  client_id text,
  client_secret text,
  refresh_expired boolean,
  time_zone text,
  auth_code text,
  token_expiration_date timestamp with time zone,
  position text,
  role text,
  phone_number text,
  access_token_2 text,
  refresh_token_2 text,
  refresh_expired_2 boolean,
  signal_source_uuid text,
  token_expiration_date_2 timestamp without time zone,
  client_id_2 text,
  client_secret_2 text,
  telegram_id text UNIQUE,
  telegram_signup_token text,
  granted_scopes jsonb,
  CONSTRAINT users_pkey PRIMARY KEY (id)
);