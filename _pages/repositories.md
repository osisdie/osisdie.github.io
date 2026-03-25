---
layout: page
permalink: /repositories/
title: repositories
description: My GitHub profile and open source repositories.
nav: true
nav_order: 4
---

{% if site.data.repositories.github_users %}

## GitHub users

<div class="repositories d-flex flex-wrap flex-md-row flex-column justify-content-between align-items-center">
  {% for user in site.data.repositories.github_users %}
    {% include repository/repo_user.liquid username=user %}
  {% endfor %}
</div>

---

{% for user in site.data.repositories.github_users %}
<div class="repositories d-flex flex-wrap flex-md-row flex-column justify-content-between align-items-center">
  <div class="repo p-2 text-center">
    <a href="https://github.com/{{ user }}">
      <img class="w-100" alt="{{ user }}" src="https://github.com/{{ user }}.png?size=200" style="border-radius: 50%; max-width: 200px;">
    </a>
    <p class="mt-2"><a href="https://github.com/{{ user }}">@{{ user }}</a></p>
  </div>
</div>

---

{% endfor %}
{% endif %}

{% if site.data.repositories.github_repos %}

## GitHub Repositories

<div class="repositories d-flex flex-wrap flex-md-row flex-column justify-content-between align-items-center">
  {% for repo in site.data.repositories.github_repos %}
    {% include repository/repo.liquid repository=repo %}
  {% endfor %}
</div>
{% endif %}
