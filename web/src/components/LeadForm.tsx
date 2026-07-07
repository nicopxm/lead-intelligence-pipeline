"use client";

import { useState, type FormEvent } from "react";
import { leadFormSchema } from "@/lib/lead";

type FieldName = "name" | "email" | "company" | "domain" | "message";

type FormState = Record<FieldName, string>;

const initialState: FormState = {
  name: "",
  email: "",
  company: "",
  domain: "",
  message: "",
};

type SubmitStatus = "idle" | "submitting" | "success" | "error";

export default function LeadForm() {
  const [values, setValues] = useState<FormState>(initialState);
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<FieldName, string>>>({});
  const [status, setStatus] = useState<SubmitStatus>("idle");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  function handleChange(field: FieldName) {
    return (event: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      setValues((prev) => ({ ...prev, [field]: event.target.value }));
    };
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setFieldErrors({});
    setErrorMessage(null);

    const parsed = leadFormSchema.safeParse(values);
    if (!parsed.success) {
      const flattened = parsed.error.flatten().fieldErrors;
      const nextFieldErrors: Partial<Record<FieldName, string>> = {};
      for (const key of Object.keys(flattened) as FieldName[]) {
        nextFieldErrors[key] = flattened[key]?.[0];
      }
      setFieldErrors(nextFieldErrors);
      return;
    }

    setStatus("submitting");
    try {
      const response = await fetch("/api/leads", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(parsed.data),
      });

      if (!response.ok) {
        const body = await response.json().catch(() => null);
        setErrorMessage(body?.error ?? "Something went wrong. Please try again.");
        setStatus("error");
        return;
      }

      setStatus("success");
      setValues(initialState);
    } catch {
      setErrorMessage("Could not reach the server. Please check your connection and try again.");
      setStatus("error");
    }
  }

  if (status === "success") {
    return (
      <div role="status" style={{ maxWidth: 480, textAlign: "center" }}>
        <h2>Thanks — we&apos;ll be in touch.</h2>
        <p>Your details were submitted successfully.</p>
      </div>
    );
  }

  return (
    <form
      onSubmit={handleSubmit}
      noValidate
      style={{ display: "flex", flexDirection: "column", gap: "1rem", width: "100%", maxWidth: 480 }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}>
        <label htmlFor="name">Name</label>
        <input id="name" name="name" value={values.name} onChange={handleChange("name")} />
        {fieldErrors.name && <span style={{ color: "#b00020" }}>{fieldErrors.name}</span>}
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}>
        <label htmlFor="email">Email</label>
        <input id="email" name="email" type="email" value={values.email} onChange={handleChange("email")} />
        {fieldErrors.email && <span style={{ color: "#b00020" }}>{fieldErrors.email}</span>}
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}>
        <label htmlFor="company">Company</label>
        <input id="company" name="company" value={values.company} onChange={handleChange("company")} />
        {fieldErrors.company && <span style={{ color: "#b00020" }}>{fieldErrors.company}</span>}
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}>
        <label htmlFor="domain">Company domain (optional)</label>
        <input
          id="domain"
          name="domain"
          placeholder="acme.com"
          value={values.domain}
          onChange={handleChange("domain")}
        />
        {fieldErrors.domain && <span style={{ color: "#b00020" }}>{fieldErrors.domain}</span>}
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}>
        <label htmlFor="message">Message</label>
        <textarea id="message" name="message" rows={4} value={values.message} onChange={handleChange("message")} />
        {fieldErrors.message && <span style={{ color: "#b00020" }}>{fieldErrors.message}</span>}
      </div>

      {status === "error" && errorMessage && (
        <div role="alert" style={{ color: "#b00020" }}>
          {errorMessage}
        </div>
      )}

      <button type="submit" disabled={status === "submitting"}>
        {status === "submitting" ? "Submitting…" : "Submit"}
      </button>
    </form>
  );
}
