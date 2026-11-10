# Task: add an opening to every Socratic problem bank

You wrote the problem banks for the Socratic tutor on ohschemlabs.com. Each bank needs two new blocks:
`\intro{...}`, a short overview of the session, and `\levelcheck{...}`, one question asking the student how
much they already know about the first topic. Add both to every bank file and change nothing else.

## How the site uses them

When a student presses **Start session**, the site shows the `\intro` text and then the `\levelcheck`
question, exactly as written, as the tutor's first message. The tutor does not generate either. Every
student sees the same words, so write them as the tutor speaking to one student.

The student then answers the question in their own words. The tutor does not grade that answer. It uses it
to choose a starting difficulty from 1 to 4 and poses the first problem at that level, on the topic the
question asked about. After that, difficulty follows how the student actually does.

## Exact format

```
\bank[slug=…, title="…", topic="…"]
\concepts{concept-a, concept-b, …}

\intro{
First paragraph.

Second paragraph.
}

\levelcheck{
One or two sentences ending in the question.
}

\problem[pid=…, …]{
…
```

- Exactly one `\intro{...}` and one `\levelcheck{...}` per file, in that order, directly after
  `\concepts{...}` and before the first `\problem`.
- The block names are lowercase letters only, spelled exactly `intro` and `levelcheck`.
- Braces must balance. `\ce{H2O}` and other LaTeX braces inside are fine.
- Plain sentences only. No Markdown, no headings, no bullets, no bold, no numbered lists.
- A blank line starts a new paragraph. Line breaks are kept as typed.
- Math uses the same notation as the problems: `$...$` inline, chemistry as `$\ce{...}$`. In `\intro`, a key
  equation may go on its own line as `$$...$$` with a blank line before and after. Use at most one or two.
- No line may begin with `%`. The parser treats such a line as a comment and deletes it.

## Writing `\intro`

- 60 to 120 words, in two short paragraphs.
- Paragraph 1: what this session is about, in plain language. Group the bank's `\concepts` into three to
  five ideas a student would recognise. Do not list the concept slugs.
- Paragraph 2: what the student should be able to do by the end, and what kind of thinking the problems
  ask for, such as explaining in words, calculating, or reading a graph.
- Speak to the student as "you". Use "we" for the session. Keep the tone calm and direct.
- Every statement must match the bank. Do not mention a topic that has no problem in the file.
- Do not end with a question. The level question follows it.

## Writing `\levelcheck`

- One or two sentences, 20 to 45 words, ending in a question.
- Ask about **one** topic: the idea the session should start with. Name it in plain words a student would
  use, not the concept slug.
- Choose that topic so the bank has problems on it at several difficulties, ideally 1 through 4. The first
  problem is picked from that topic at the level the student reports. If the natural first topic has only
  one difficulty, pick the nearest early topic that has a spread, and say so in your notes back to the owner.
- Invite an honest, short answer and make "it is all new" an acceptable one. Give the student a sense of
  what to say: what they have seen, what they can do, what confuses them.
- It is not a quiz. Do not ask them to define, calculate or explain anything.

## What to leave out of both blocks

- No greeting by name, and no name for the tutor.
- No reference to any specific problem.
- No count of problems, no time estimate, no promise about grades.
- No description of buttons, tabs, levels or how the site works. Do not mention difficulty numbers.
- No answers, hints or worked results from the problems.

## Do not change anything else

Student sessions are stored against the problem ids. Leave every `pid`, the `\concepts` list, and all
problem text, answers, rubrics and options byte for byte as they are. The only difference between the old
file and the new file is the two added blocks and the blank lines around them.

## Example

```
\intro{
This session is about heat and temperature. We will separate the two ideas, look at why some materials
warm faster than others, and use specific heat to follow energy as it moves between objects.

$$q = mc\Delta T$$

By the end you should be able to explain in words where the energy goes when something warms or cools,
and calculate a temperature change, a mass or a specific heat from the other quantities, including in
a simple calorimeter. Expect to explain your reasoning, not only give a number.
}

\levelcheck{
Before the first problem, tell me where you stand on the difference between heat and temperature. Have
you worked with it before, and how confident do you feel about it? It is fine to say it is all new.
}
```

## Checklist before returning each file

1. One `\intro{...}` then one `\levelcheck{...}`, directly after `\concepts{...}`.
2. Braces balanced, no line starting with `%`, no Markdown.
3. `\intro` is 60 to 120 words and names only topics the bank has problems for.
4. `\levelcheck` asks about one topic that has problems at several difficulties, and is not a quiz.
5. Nothing else in the file differs from the original.
6. Return the complete file as `.txt`, with the same file name as before.
7. For each bank, tell the owner which topic the level question asks about and which difficulties that
   topic has problems at.

## Note for the owner

Upload each returned file on the tutor's page in the Widgets tab, into its existing bank, and save. The
check line under the text box should then show "opening overview" and "level question". A bank without the
blocks still works: students get no overview and the site asks a general question instead.
