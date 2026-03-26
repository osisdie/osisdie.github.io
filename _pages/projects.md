---
layout: page
title: projects
permalink: /projects/
description: Open source projects and experiments.
nav: true
nav_order: 3
display_categories: [claude, openclaw, ai, agent, game, dotnet, tool, programming]
horizontal: false
---

<!-- GitHub profile -->
<div class="repositories d-flex flex-wrap flex-md-row flex-column justify-content-between align-items-center mb-4">
  <div class="repo p-2 text-center">
    <a href="https://github.com/osisdie">
      <img class="w-100" alt="osisdie" src="https://github.com/osisdie.png?size=200" style="border-radius: 50%; max-width: 200px;">
    </a>
    <p class="mt-2"><a href="https://github.com/osisdie">@osisdie</a></p>
  </div>
</div>

<hr>

<!-- pages/projects.md -->
<div class="projects">
{% if site.enable_project_categories and page.display_categories %}
  <!-- Display categorized projects -->
  {% for category in page.display_categories %}
  <a id="{{ category }}" href=".#{{ category }}">
    <h2 class="category">{{ category }}</h2>
  </a>
  {% assign categorized_projects = site.projects | where: "category", category %}
  {% assign sorted_projects = categorized_projects | sort: "importance" %}
  <!-- Generate cards for each project -->
  {% if page.horizontal %}
  <div class="container">
    <div class="row row-cols-1 row-cols-md-2">
    {% for project in sorted_projects %}
      {% include projects_horizontal.liquid %}
    {% endfor %}
    </div>
  </div>
  {% else %}
  <div class="row row-cols-1 row-cols-md-3">
    {% for project in sorted_projects %}
      {% include projects.liquid %}
    {% endfor %}
  </div>
  {% endif %}
  {% endfor %}

{% else %}

<!-- Display projects without categories -->

{% assign sorted_projects = site.projects | sort: "importance" %}

  <!-- Generate cards for each project -->

{% if page.horizontal %}

  <div class="container">
    <div class="row row-cols-1 row-cols-md-2">
    {% for project in sorted_projects %}
      {% include projects_horizontal.liquid %}
    {% endfor %}
    </div>
  </div>
  {% else %}
  <div class="row row-cols-1 row-cols-md-3">
    {% for project in sorted_projects %}
      {% include projects.liquid %}
    {% endfor %}
  </div>
  {% endif %}
{% endif %}
</div>
