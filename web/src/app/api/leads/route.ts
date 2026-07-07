import { NextResponse } from "next/server";
import { ZodError } from "zod";
import { buildLeadIntakePayload, leadFormSchema } from "@/lib/lead";

export async function POST(request: Request) {
  const webhookUrl = process.env.LEAD_INTAKE_WEBHOOK_URL;
  if (!webhookUrl) {
    console.error("LEAD_INTAKE_WEBHOOK_URL is not set");
    return NextResponse.json(
      { error: "Server is not configured to accept leads right now." },
      { status: 500 },
    );
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid request body." }, { status: 400 });
  }

  const parsed = leadFormSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Invalid submission.", details: (parsed.error as ZodError).flatten() },
      { status: 400 },
    );
  }

  const payload = buildLeadIntakePayload(parsed.data);

  let webhookResponse: Response;
  try {
    webhookResponse = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (error) {
    console.error("Lead intake webhook request failed", error);
    return NextResponse.json(
      { error: "Could not reach the intake service. Please try again." },
      { status: 502 },
    );
  }

  if (!webhookResponse.ok) {
    console.error("Lead intake webhook rejected the payload", webhookResponse.status);
    return NextResponse.json(
      { error: "Could not submit your details right now. Please try again." },
      { status: 502 },
    );
  }

  return NextResponse.json({ status: "ok" }, { status: 200 });
}
